//
//  GATTServer.swift
//  Bluetooth
//
//  Created by Alsey Coleman Miller on 2/29/16.
//  Copyright © 2016 PureSwift. All rights reserved.
//

import Foundation

public extension GATT {
    
    public typealias Server = GATTServer
}

public final class GATTServer {
    
    // MARK: - Properties
    
    public var log: ((String) -> ())?
    
    public var writePending: (() -> ())? {
        
        get { return connection.writePending }
        
        set { connection.writePending = newValue }
    }
    
    public private(set) var maximumTransmissionUnit: ATTMaximumTransmissionUnit {
        
        get { return connection.maximumTransmissionUnit }
        
        set { connection.maximumTransmissionUnit = newValue }
    }
    
    public let preferredMaximumTransmissionUnit: ATTMaximumTransmissionUnit
    
    public let maximumPreparedWrites: Int
    
    public var database = GATTDatabase()
    
    public var willRead: ((_ uuid: BluetoothUUID, _ handle: UInt16, _ value: Data, _ offset: Int) -> ATT.Error?)?
    
    public var willWrite: ((_ uuid: BluetoothUUID, _ handle: UInt16, _ value: Data, _ newValue: Data) -> ATT.Error?)?
    
    public var didWrite: ((_ uuid: BluetoothUUID, _ handle: UInt16, _ value: Data) -> Void)?
    
    // Don't modify
    internal let connection: ATTConnection
    
    private var preparedWrites = [PreparedWrite]()
    
    // MARK: - Initialization
    
    public init(socket: L2CAPSocketProtocol,
                maximumTransmissionUnit: ATT.MaximumTransmissionUnit = .default,
                maximumPreparedWrites: Int = 50) {
        
        // set initial MTU and register handlers
        self.maximumPreparedWrites = maximumPreparedWrites
        self.preferredMaximumTransmissionUnit = maximumTransmissionUnit
        self.connection = ATTConnection(socket: socket)
        self.registerATTHandlers()
    }
    
    // MARK: - Methods
    
    /// Performs the actual IO for sending data.
    public func read() throws -> Bool {
        
        return try connection.read()
    }
    
    /// Performs the actual IO for recieving data.
    public func write() throws -> Bool {
        
        return try connection.write()
    }
    
    /// Update the value of a characteristic attribute.
    public func writeValue(_ value: Data, forCharacteristic handle: UInt16) {
        
        database.write(value, forAttribute: handle)
        
        didWriteAttribute(handle)
    }
    
    /// Update the value of a characteristic attribute.
    public func writeValue(_ value: Data, forCharacteristic uuid: BluetoothUUID) {
        
        guard let attribute = database.first(where: { $0.uuid == uuid })
            else { fatalError("Invalid uuid \(uuid)") }
        
        writeValue(value, forCharacteristic: attribute.handle)
    }
    
    // MARK: - Private Methods
    
    @inline(__always)
    private func registerATTHandlers() {
        
        // Exchange MTU
        connection.register { [weak self] in self?.exchangeMTU($0) }
        
        // Read By Group Type
        connection.register { [weak self] in self?.readByGroupType($0) }
        
        // Read By Type
        connection.register { [weak self] in self?.readByType($0) }
        
        // Find Information
        connection.register { [weak self] in self?.findInformation($0) }
        
        // Find By Type Value
        connection.register { [weak self] in self?.findByTypeValue($0) }
        
        // Write Request
        connection.register { [weak self] in self?.writeRequest($0) }
        
        // Write Command
        connection.register { [weak self] in self?.writeCommand($0) }
        
        // Read Request
        connection.register { [weak self] in self?.readRequest($0) }
        
        // Read Blob Request
        connection.register { [weak self] in self?.readBlobRequest($0) }
        
        // Read Multiple Request
        connection.register { [weak self] in self?.readMultipleRequest($0) }
        
        // Prepare Write Request
        connection.register { [weak self] in self?.prepareWriteRequest($0) }
        
        // Execute Write Request
        connection.register { [weak self] in self?.executeWriteRequest($0) }
    }
    
    @inline(__always)
    private func errorResponse(_ opcode: ATT.Opcode, _ error: ATT.Error, _ handle: UInt16 = 0) {
        
        log?("Error \(error) - \(opcode) (\(handle))")
        
        guard let _ = connection.send(error: error, opcode: opcode, handle: handle)
            else { fatalError("Could not add error PDU to queue: \(opcode) \(error) \(handle)") }
    }
    
    @inline(__always)
    private func fatalErrorResponse(_ message: String, _ opcode: ATT.Opcode, _ handle: UInt16 = 0, line: UInt = #line) -> Never {
        
        errorResponse(opcode, .unlikelyError, handle)
        
        do { let _ = try connection.write() }
        
        catch { log?("Could not send .unlikelyError to client. (\(error))") }
        
        fatalError(message, line: line)
    }
    
    /// Respond to a client-initiated PDU message.
    @inline(__always)
    private func respond <T: ATTProtocolDataUnit> (_ response: T) {
        
        log?("Response: \(response)")
        
        guard let _ = connection.send(response)
            else { fatalError("Could not add PDU to queue: \(response)") }
    }
    
    /// Send a server-initiated PDU message.
    @inline(__always)
    private func send (_ indication: ATTHandleValueIndication, response: @escaping (ATTResponse<ATTHandleValueConfirmation>) -> ()) {
        
        log?("Indication: \(indication)")
        
        let callback: (AnyATTResponse) -> () = { response(ATTResponse<ATTHandleValueConfirmation>($0)) }
        
        guard let _ = connection.send(indication, response: (callback, ATTHandleValueConfirmation.self))
            else { fatalError("Could not add PDU to queue: \(indication)") }
    }
    
    /// Send a server-initiated PDU message.
    @inline(__always)
    private func send (_ notification: ATTHandleValueNotification) {
        
        log?("Notification: \(notification)")
        
        guard let _ = connection.send(notification)
            else { fatalError("Could not add PDU to queue: \(notification)") }
    }
    
    private func checkPermissions(_ permissions: BitMaskOptionSet<ATT.AttributePermission>,
                                  _ attribute: GATTDatabase.Attribute) -> ATT.Error? {
        
        guard attribute.permissions != permissions else { return nil }
        
        // check permissions
        
        if permissions.contains(.read) && !attribute.permissions.contains(.read) {
            
            return .readNotPermitted
        }
        
        if permissions.contains(.write) && !attribute.permissions.contains(.write) {
            
            return .writeNotPermitted
        }
        
        // check security
        
        let security = connection.socket.securityLevel
        
        if attribute.permissions.contains(.readAuthentication)
            || attribute.permissions.contains(.writeAuthentication)
            && security < .high {
            
            return .insufficientAuthentication
        }
        
        if attribute.permissions.contains(.readEncrypt)
            || attribute.permissions.contains(.writeEncrypt)
            && security < .medium {
            
            return .insufficientEncryption
        }
        
        return nil
    }
    
    /// Handler for Write Request and Command
    private func handleWriteRequest(opcode: ATT.Opcode, handle: UInt16, value: Data, shouldRespond: Bool) {
        
        /// Conditionally respond
        @inline(__always)
        func doResponse( _ block: @autoclosure() -> ()) {
            
            if shouldRespond { block() }
        }
        
        log?("Write \(shouldRespond ? "Request" : "Command") (\(handle)) \(value)")
        
        // no attributes, impossible to write
        guard database.attributes.isEmpty == false
            else { doResponse(errorResponse(opcode, .invalidHandle, handle)); return }
        
        // validate handle
        guard database.contains(handle: handle)
            else { errorResponse(opcode, .invalidHandle, handle); return }
        
        // get attribute
        let attribute = database[handle: handle]
        
        // validate permissions
        if let error = checkPermissions([.write, .writeAuthentication, .writeEncrypt], attribute) {
            
            doResponse(errorResponse(opcode, error, handle))
            return
        }
        
        // validate application errors with write callback
        if let error = willWrite?(attribute.uuid, handle, attribute.value, value) {
            
            doResponse(errorResponse(opcode, error, handle))
            return
        }
        
        database.write(value, forAttribute: handle)
        
        doResponse(respond(ATTWriteResponse()))
        
        didWriteAttribute(handle)
    }
    
    private func didWriteAttribute(_ attributeHandle: UInt16) {
        
        let (group, attribute) = database.attributeGroup(for: attributeHandle)
        assert(attribute.handle == attributeHandle)
        
        guard let service = group.service,
            let characteristic = service.characteristics.first(where: { $0.uuid == attribute.uuid })
            else { return }
        
        // inform delegate
        didWrite?(attribute.uuid, attribute.handle, attribute.value)
        
        // Client configuration
        if let clientConfigurationDescriptor = characteristic.descriptors.first(where: { $0.uuid == .clientCharacteristicConfiguration }) {
            
            guard let descriptor = GATTClientCharacteristicConfiguration(data: clientConfigurationDescriptor.value)
                else { return }
            
            // notify
            if descriptor.configuration.contains(.notify) {
                
                let notification = ATTHandleValueNotification(attribute: attribute, maximumTransmissionUnit: connection.maximumTransmissionUnit)
                
                send(notification)
            }
            
            // indicate
            if descriptor.configuration.contains(.indicate) {
                
                let indication = ATTHandleValueIndication(attribute: attribute, maximumTransmissionUnit: connection.maximumTransmissionUnit)
                
                send(indication) { [unowned self] (confirmation) in
                    
                    self.log?("Confirmation: \(confirmation)")
                }
            }
        }
    }
    
    private func handleReadRequest(opcode: ATT.Opcode,
                                   handle: UInt16,
                                   offset: UInt16 = 0,
                                   isBlob: Bool = false) -> Data? {
        
        // no attributes
        guard database.attributes.isEmpty == false
            else { errorResponse(opcode, .invalidHandle, handle); return nil }
        
        // validate handle
        guard database.contains(handle: handle)
            else { errorResponse(opcode, .invalidHandle, handle); return nil }
        
        // get attribute
        let attribute = database[handle: handle]
        
        // validate permissions
        if let error = checkPermissions([.read, .readAuthentication, .readEncrypt], attribute) {
            
            errorResponse(opcode, error, handle)
            return nil
        }
        
        // Verify attribute value size for blob reading
        //
        // If the Characteristic Value is not longer than (ATT_MTU – 1) an Error Response with
        // the Error Code set to Attribute Not Long shall be received on the first Read Blob Request.
        guard isBlob == false || attribute.value.count > (Int(connection.maximumTransmissionUnit.rawValue) - 1)
            else { errorResponse(opcode, .attributeNotLong, handle); return nil }
        
        // check boundary
        guard offset <= UInt16(attribute.value.count)
            else { errorResponse(opcode, .invalidOffset, handle); return nil }
        
        var value: Data
        
        // Guard against invalid access if offset equals to value length
        if offset == UInt16(attribute.value.count) {
            
            value = Data()
            
        } else if offset > 0 {
            
            value = Data(attribute.value.suffix(from: Int(offset)))
            
        } else {
            
            value = attribute.value
        }
        
        // adjust value for MTU
        value = Data(value.prefix(Int(connection.maximumTransmissionUnit.rawValue) - 1))
        
        // validate application errors with read callback
        if let error = willRead?(attribute.uuid, handle, value, Int(offset)) {
            
            errorResponse(opcode, error, handle)
            return nil
        }
        
        return value
    }
    
    // MARK: Callbacks
    
    private func exchangeMTU(_ pdu: ATTMaximumTransmissionUnitRequest) {
        
        let serverMTU = preferredMaximumTransmissionUnit.rawValue
        
        let finalMTU = ATTMaximumTransmissionUnit(server: serverMTU, client: pdu.clientMTU)
        
        // Respond with the server MTU (not final MTU)
        connection.send(ATTMaximumTransmissionUnitResponse(serverMTU: serverMTU))
        
        // Set MTU
        maximumTransmissionUnit = finalMTU
        
        log?("MTU Exchange (\(pdu.clientMTU) -> \(serverMTU))")
    }
    
    private func readByGroupType(_ pdu: ATTReadByGroupTypeRequest) {
        
        typealias AttributeData = ATTReadByGroupTypeResponse.AttributeData
        
        log?("Read by Group Type (\(pdu.startHandle) - \(pdu.endHandle))")
        
        // validate handles
        guard pdu.startHandle != 0 && pdu.endHandle != 0
            else { errorResponse(type(of: pdu).attributeOpcode, .invalidHandle); return }
        
        guard pdu.startHandle <= pdu.endHandle
            else { errorResponse(type(of: pdu).attributeOpcode, .invalidHandle, pdu.startHandle); return }
        
        // GATT defines that only the Primary Service and Secondary Service group types 
        // can be used for the "Read By Group Type" request. Return an error if any other group type is given.
        guard pdu.type == .primaryService
            || pdu.type == .secondaryService
            else { errorResponse(type(of: pdu).attributeOpcode, .unsupportedGroupType, pdu.startHandle); return }
        
        let attributeData = database.readByGroupType(handle: (pdu.startHandle, pdu.endHandle), type: pdu.type)
        
        guard let firstAttribute = attributeData.first
            else { errorResponse(type(of: pdu).attributeOpcode, .attributeNotFound, pdu.startHandle); return }
        
        let mtu = Int(connection.maximumTransmissionUnit.rawValue)
        
        let valueLength = firstAttribute.value.count
        
        let response: ATTReadByGroupTypeResponse
        
        // truncate for MTU if first handle is too large
        if ATTReadByGroupTypeResponse([firstAttribute]).dataLength > mtu {
            
            let maxLength = min(min(mtu - 6, 251), valueLength)
            
            let truncatedAttribute = AttributeData(attributeHandle: firstAttribute.attributeHandle,
                                                   endGroupHandle: firstAttribute.endGroupHandle,
                                                   value: Data(firstAttribute.value.prefix(maxLength)))
            
            response = ATTReadByGroupTypeResponse([truncatedAttribute])
            
        } else {
            
            var count = 1
            
            // respond with results that are the same length
            if attributeData.count > 1 {
                
                for (index, attribute) in attributeData.suffix(from: 1).enumerated() {
                    
                    let newCount = index + 1
                    
                    guard attribute.value.count == valueLength,
                        ATTReadByGroupTypeResponse.dataLength(for: attributeData.prefix(newCount)) <= mtu
                        else { break }
                    
                    count = newCount
                }
            }
            
            let limitedAttributes = Array(attributeData.prefix(count))
            
            response = ATTReadByGroupTypeResponse(limitedAttributes)
        }
        
        assert(response.dataLength <= mtu,
               "Response \(response.dataLength) bytes > MTU (\(mtu))")
        
        respond(response)
    }
    
    private func readByType(_ pdu: ATTReadByTypeRequest) {
        
        typealias AttributeData = ATTReadByTypeResponse.AttributeData
        
        log?("Read by Type (\(pdu.attributeType)) (\(pdu.startHandle) - \(pdu.endHandle))")
        
        guard pdu.startHandle != 0 && pdu.endHandle != 0
            else { errorResponse(type(of: pdu).attributeOpcode, .invalidHandle); return }
        
        guard pdu.startHandle <= pdu.endHandle
            else { errorResponse(type(of: pdu).attributeOpcode, .invalidHandle, pdu.startHandle); return }
        
        let attributeData = database
            .readByType(handle: (pdu.startHandle, pdu.endHandle), type: pdu.attributeType)
            .map { AttributeData(handle: $0.handle, value: $0.value) }
        
        guard let firstAttribute = attributeData.first
            else { errorResponse(type(of: pdu).attributeOpcode, .attributeNotFound, pdu.startHandle); return }
        
        let mtu = Int(connection.maximumTransmissionUnit.rawValue)
        
        let valueLength = firstAttribute.value.count
        
        let response: ATTReadByTypeResponse
        
        // truncate data for MTU if first handle is too large
        if ATTReadByTypeResponse([firstAttribute]).dataLength > mtu {
            
            let maxLength = min(min(mtu - 4, 253), firstAttribute.value.count)
            
            let truncatedAttribute = AttributeData(handle: firstAttribute.handle,
                                                   value: Data(firstAttribute.value.prefix(maxLength)))
            
            response = ATTReadByTypeResponse([truncatedAttribute])
            
        } else {
            
            var count = 1
            
            // respond with results that are the same length
            if attributeData.count > 1 {
                
                for (index, attribute) in attributeData.suffix(from: 1).enumerated() {
                    
                    let newCount = index + 1
                    
                    guard attribute.value.count == valueLength,
                        ATTReadByTypeResponse.dataLength(for: attributeData.prefix(newCount)) <= mtu
                        else { break }
                    
                    count = newCount
                }
            }
            
            let limitedAttributes = Array(attributeData.prefix(count))
            
            response = ATTReadByTypeResponse(limitedAttributes)
        }
        
        assert(response.dataLength <= mtu,
               "Response \(response.dataLength) bytes > MTU (\(mtu))")
        
        respond(response)
    }
    
    private func findInformation(_ pdu: ATTFindInformationRequest) {
        
        typealias AttributeData = ATTFindInformationResponse.AttributeData
        
        typealias Format = ATTFindInformationResponse.Format
        
        let opcode = type(of: pdu).attributeOpcode
        
        log?("Find Information (\(pdu.startHandle) - \(pdu.endHandle))")
        
        guard pdu.startHandle != 0 && pdu.endHandle != 0
            else { errorResponse(opcode, .invalidHandle); return }
        
        guard pdu.startHandle <= pdu.endHandle
            else { errorResponse(opcode, .invalidHandle, pdu.startHandle); return }
        
        let attributes = database.findInformation(handle: (pdu.startHandle, pdu.endHandle))
        
        guard attributes.isEmpty == false
            else { errorResponse(opcode, .attributeNotFound, pdu.startHandle); return }
        
        guard let format = Format(uuid: attributes[0].uuid)
            else { errorResponse(opcode, .unlikelyError, pdu.startHandle); return }
        
        var bit16Pairs = [ATTFindInformationResponse.Attribute16Bit]()
        var bit128Pairs = [ATTFindInformationResponse.Attribute128Bit]()
        
        for (index, attribute) in attributes.enumerated() {
            
            // truncate if bigger than MTU
            let encodedLength = 2 + ((index + 1) * format.length)
            
            guard encodedLength <= Int(connection.maximumTransmissionUnit.rawValue)
                else { break }
            
            var mismatchedType = false
            
            // encode attribute
            switch (attribute.uuid, format) {
                
            case let (.bit16(type), .bit16):
                
                bit16Pairs.append(ATTFindInformationResponse.Attribute16Bit(handle: attribute.handle, uuid: type))
                
            case let (.bit128(type), .bit128):
                
                bit128Pairs.append(ATTFindInformationResponse.Attribute128Bit(handle: attribute.handle, uuid: type))
                
            default:
                
                mismatchedType = true // mismatching types
            }
            
            // stop enumerating
            guard mismatchedType == false
                else { break }
        }
        
        let attributeData: AttributeData
        
        switch format {
        case .bit16: attributeData = .bit16(bit16Pairs)
        case .bit128: attributeData = .bit128(bit128Pairs)
        }
        
        let response = ATTFindInformationResponse(attributeData: attributeData)
        
        respond(response)
    }
    
    private func findByTypeValue(_ pdu: ATTFindByTypeRequest) {
        
        typealias Handle = ATTFindByTypeResponse.HandlesInformation
        
        log?("Find By Type Value (\(pdu.startHandle) - \(pdu.endHandle)) (\(pdu.attributeType))")
        
        guard pdu.startHandle != 0 && pdu.endHandle != 0
            else { errorResponse(type(of: pdu).attributeOpcode, .invalidHandle); return }
        
        guard pdu.startHandle <= pdu.endHandle
            else { errorResponse(type(of: pdu).attributeOpcode, .invalidHandle, pdu.startHandle); return }
        
        let handles = database.findByTypeValue(handle: (pdu.startHandle, pdu.endHandle),
                                               type: pdu.attributeType,
                                               value: pdu.attributeValue)
        
        guard handles.isEmpty == false
            else { errorResponse(type(of: pdu).attributeOpcode, .attributeNotFound, pdu.startHandle); return }
        
        let response = ATTFindByTypeResponse(handles)
        
        respond(response)
    }
    
    private func writeRequest(_ pdu: ATTWriteRequest) {
        
        let opcode = type(of: pdu).attributeOpcode
        
        handleWriteRequest(opcode: opcode, handle: pdu.handle, value: pdu.value, shouldRespond: true)
    }
    
    private func writeCommand(_ pdu: ATTWriteCommand) {
        
        let opcode = type(of: pdu).attributeOpcode
        
        handleWriteRequest(opcode: opcode, handle: pdu.handle, value: pdu.value, shouldRespond: false)
    }
    
    private func readRequest(_ pdu: ATTReadRequest) {
        
        let opcode = type(of: pdu).attributeOpcode
        
        log?("Read (\(pdu.handle))")
        
        if let value = handleReadRequest(opcode: opcode, handle: pdu.handle) {
            
            respond(ATTReadResponse(attributeValue: value))
        }
    }
    
    private func readBlobRequest(_ pdu: ATTReadBlobRequest) {
        
        let opcode = type(of: pdu).attributeOpcode
        
        log?("Read Blob (\(pdu.handle))")
        
        if let value = handleReadRequest(opcode: opcode, handle: pdu.handle, offset: pdu.offset, isBlob: true) {
            
            respond(ATTReadBlobResponse(partAttributeValue: value))
        }
    }
    
    private func readMultipleRequest(_ pdu: ATTReadMultipleRequest) {
        
        let opcode = type(of: pdu).attributeOpcode
        
        log?("Read Multiple Request \(pdu.handles)")
        
        // no attributes, impossible to read
        guard database.attributes.isEmpty == false
            else { errorResponse(opcode, .invalidHandle, pdu.handles[0]); return }
        
        var values = Data()
        
        for handle in pdu.handles {
            
            // validate handle
            guard database.contains(handle: handle)
                else { errorResponse(opcode, .invalidHandle, handle); return }
            
            // get attribute
            let attribute = database[handle: handle]
            
            // validate application errors with read callback
            if let error = willRead?(attribute.uuid, handle, attribute.value, 0) {
                
                errorResponse(opcode, error, handle)
                return
            }
            
            values += attribute.value
        }
        
        let response = ATTReadMultipleResponse(values: values)
        
        respond(response)
    }
    
    private func prepareWriteRequest(_ pdu: ATTPrepareWriteRequest) {
        
        let opcode = type(of: pdu).attributeOpcode
        
        log?("Prepare Write Request (\(pdu.handle))")
        
        // no attributes, impossible to write
        guard database.attributes.isEmpty == false
            else { errorResponse(opcode, .invalidHandle, pdu.handle); return }
        
        // validate handle
        guard database.contains(handle: pdu.handle)
            else { errorResponse(opcode, .invalidHandle, pdu.handle); return }
        
        // validate that the prepared writes queue is not full
        guard preparedWrites.count <= maximumPreparedWrites
            else { errorResponse(opcode, .prepareQueueFull); return }
        
        // get attribute
        let attribute = database[handle: pdu.handle]
        
        // validate permissions
        if let error = checkPermissions([.write, .writeAuthentication, .writeEncrypt], attribute) {
            
            errorResponse(opcode, error, pdu.handle)
            return
        }
        
        // The Attribute Value validation is done when an Execute Write Request is received.
        // Hence, any Invalid Offset or Invalid Attribute Value Length errors are generated 
        // when an Execute Write Request is received.
        
        // add queued write
        let preparedWrite = PreparedWrite(handle: pdu.handle, value: pdu.partValue, offset: pdu.offset)
        
        preparedWrites.append(preparedWrite)
        
        let response = ATTPrepareWriteResponse(handle: pdu.handle, offset: pdu.offset, partValue: pdu.partValue)
        
        respond(response)
    }
    
    private func executeWriteRequest(_ pdu: ATTExecuteWriteRequest) {
        
        let opcode = type(of: pdu).attributeOpcode
        
        log?("Execute Write Request (\(pdu))")
        
        let preparedWrites = self.preparedWrites
        self.preparedWrites = []
        
        var newValues = [UInt16: Data]()
        
        switch pdu {
            
        case .cancel:
            
            break // queue always cleared
            
        case .write:
            
            // validate
            for write in preparedWrites {
                
                let previousValue = newValues[write.handle] ?? Data()
                
                let newValue = previousValue + write.value
                
                // validate offset?
                newValues[write.handle] = newValue
            }
            
            // validate new values
            for (handle, newValue) in newValues {
                
                let attribute = database[handle: handle]
                
                // validate application errors with write callback
                if let error = willWrite?(attribute.uuid, handle, attribute.value, newValue) {
                    
                    errorResponse(opcode, error, handle)
                    return
                }
            }
            
            // write new values
            for (handle, newValue) in newValues {
                
                database.write(newValue, forAttribute: handle)
            }
        }
        
        respond(ATTExecuteWriteResponse())
        
        for handle in newValues.keys {
            
            didWriteAttribute(handle)
        }
    }
}

// MARK: - Supporting Types

private extension GATTServer {
    
    struct PreparedWrite {
        
        let handle: UInt16
        
        let value: Data
        
        let offset: UInt16
    }
}

// MARK: - GATTDatabase Extensions

internal struct HandleRange {
    
    public let start: UInt16
    
    public let end: UInt16
    
    public init(start: UInt16, end: UInt16) {
        assert(start <= end)
        self.start = start
        self.end = end
    }
}

internal extension HandleRange {
    
    init(group: GATTDatabase.AttributeGroup) {
        
        self.init(start: group.startHandle, end: group.endHandle)
    }
}

internal extension HandleRange {
    
    func isSubset(_ other: HandleRange) -> Bool {
        
        return self.start >= other.start
            && self.start <= other.end
            && self.end >= other.start
            && self.end <= other.end
    }
    
    func contains(_ element: UInt16) -> Bool {
        
        return start <= element
            && element <= end
    }
}

internal extension GATTDatabase {
    
    /// Find the enclosing Service attribute group for the specified handle
    func attributeGroup(for handle: UInt16) -> (group: AttributeGroup, attribute: Attribute) {
        
        for group in attributeGroups {
            
            for attribute in group.attributes {
                
                guard attribute.handle != handle
                    else { return (group, attribute) }
            }
        }
        
        fatalError("Invalid handle \(handle)")
    }
    
    /// Used for Service discovery.
    func readByGroupType(handle: (start: UInt16, end: UInt16), type: BluetoothUUID) -> [ATTReadByGroupTypeResponse.AttributeData] {
        
        typealias AttributeData = ATTReadByGroupTypeResponse.AttributeData
        
        var data = [AttributeData]()
        data.reserveCapacity(attributeGroups.count)
        
        let handleRange = HandleRange(start: handle.start, end: handle.end)
        
        for group in attributeGroups {
            
            let groupRange = HandleRange(group: group)
            
            guard group.serviceAttribute.uuid == type,
                groupRange.isSubset(handleRange)
                else { continue }
            
            data.append(AttributeData(attributeHandle: group.startHandle,
                                      endGroupHandle: group.endHandle,
                                      value: group.serviceAttribute.value))
        }
        
        return data
    }
    
    func readByType(handle: (start: UInt16, end: UInt16), type: BluetoothUUID) -> [Attribute] {
        
        let range = HandleRange(start: handle.start, end: handle.end)
        
        return attributes.filter { range.contains($0.handle) && $0.uuid == type }
    }
    
    func findInformation(handle: (start: UInt16, end: UInt16)) -> [Attribute] {
        
        let range = HandleRange(start: handle.start, end: handle.end)
        
        return attributes.filter { range.contains($0.handle) }
    }
    
    func findByTypeValue(handle: (start: UInt16, end: UInt16), type: UInt16, value: Data) -> [ATTFindByTypeResponse.HandlesInformation] {
        
        typealias HandleInformation = ATTFindByTypeResponse.HandlesInformation
        
        let range = HandleRange(start: handle.start, end: handle.end)
        
        var results = [HandleInformation]()
        
        for group in attributeGroups {
            
            for attribute in group.attributes {
                
                let match = range.contains(attribute.handle)
                    && attribute.uuid == .bit16(type)
                    && attribute.value == value
                
                guard match else { continue }
                
                results.append(HandleInformation(foundAttribute: group.startHandle, groupEnd: group.endHandle))
            }
        }
        
        return results
    }
}
