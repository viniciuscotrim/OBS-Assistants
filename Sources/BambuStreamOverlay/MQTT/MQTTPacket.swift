import Foundation

/// Minimal MQTT 3.1.1 packet encode/decode — just enough for what a Bambu
/// printer's local broker needs: CONNECT/CONNACK, SUBSCRIBE/SUBACK,
/// PUBLISH (receive + the one publish we do, "pushall"), PINGREQ/PINGRESP,
/// DISCONNECT. Not a general-purpose MQTT stack.
enum MQTTPacketType: UInt8 {
    case connect = 1
    case connack = 2
    case publish = 3
    case puback = 4
    case subscribe = 8
    case suback = 9
    case pingreq = 12
    case pingresp = 13
    case disconnect = 14
}

enum MQTTEncode {
    /// MQTT "remaining length" variable-length encoding (1-4 bytes).
    static func remainingLength(_ length: Int) -> [UInt8] {
        var value = length
        var bytes: [UInt8] = []
        repeat {
            var digit = UInt8(value % 128)
            value /= 128
            if value > 0 { digit |= 0x80 }
            bytes.append(digit)
        } while value > 0
        return bytes
    }

    /// 2-byte-length-prefixed UTF-8 string, as used throughout MQTT.
    static func string(_ s: String) -> [UInt8] {
        let utf8 = Array(s.utf8)
        let len = UInt16(utf8.count)
        return [UInt8(len >> 8), UInt8(len & 0xFF)] + utf8
    }

    static func connect(clientID: String, username: String, password: String, keepAlive: UInt16 = 60) -> Data {
        var variableHeader: [UInt8] = []
        variableHeader += string("MQTT")
        variableHeader += [4] // protocol level 4 = MQTT 3.1.1

        var connectFlags: UInt8 = 0x02 // clean session
        connectFlags |= 0x80 // username present
        connectFlags |= 0x40 // password present
        variableHeader += [connectFlags]
        variableHeader += [UInt8(keepAlive >> 8), UInt8(keepAlive & 0xFF)]

        var payload: [UInt8] = []
        payload += string(clientID)
        payload += string(username)
        payload += string(password)

        let body = variableHeader + payload
        var packet: [UInt8] = [MQTTPacketType.connect.rawValue << 4]
        packet += remainingLength(body.count)
        packet += body
        return Data(packet)
    }

    static func subscribe(packetID: UInt16, topic: String, qos: UInt8 = 0) -> Data {
        var body: [UInt8] = [UInt8(packetID >> 8), UInt8(packetID & 0xFF)]
        body += string(topic)
        body += [qos]

        var packet: [UInt8] = [(MQTTPacketType.subscribe.rawValue << 4) | 0x02]
        packet += remainingLength(body.count)
        packet += body
        return Data(packet)
    }

    static func publish(topic: String, payload: Data, qos: UInt8 = 0) -> Data {
        var body: [UInt8] = string(topic)
        // QoS 0: no packet identifier.
        body += [UInt8](payload)

        var packet: [UInt8] = [MQTTPacketType.publish.rawValue << 4]
        packet += remainingLength(body.count)
        packet += body
        return Data(packet)
    }

    static func pingreq() -> Data {
        Data([MQTTPacketType.pingreq.rawValue << 4, 0])
    }

    static func disconnect() -> Data {
        Data([MQTTPacketType.disconnect.rawValue << 4, 0])
    }
}

struct MQTTRawPacket {
    let typeByte: UInt8 // full first byte (type + flags)
    let payload: Data

    var type: UInt8 { typeByte >> 4 }
}

/// Incrementally parses complete MQTT packets out of a growing byte buffer,
/// since TCP/TLS reads don't line up with packet boundaries.
struct MQTTPacketReader {
    private var buffer = Data()

    mutating func append(_ data: Data) {
        buffer.append(data)
    }

    /// Pulls out every complete packet currently available in the buffer.
    mutating func drainPackets() -> [MQTTRawPacket] {
        var result: [MQTTRawPacket] = []
        while let packet = tryParseOne() {
            result.append(packet)
        }
        return result
    }

    private mutating func tryParseOne() -> MQTTRawPacket? {
        guard buffer.count >= 2 else { return nil }
        let bytes = buffer
        let start = bytes.startIndex
        let typeByte = bytes[start]

        // Decode the variable-length "remaining length" field (1-4 bytes).
        var multiplier = 1
        var value = 0
        var index = bytes.index(after: start)
        var lengthByteCount = 0
        var encodedByte: UInt8 = 0
        repeat {
            guard index < bytes.endIndex else { return nil } // need more data
            encodedByte = bytes[index]
            value += Int(encodedByte & 0x7F) * multiplier
            multiplier *= 128
            index = bytes.index(after: index)
            lengthByteCount += 1
            if lengthByteCount > 4 {
                // Malformed packet; drop everything to avoid getting stuck.
                buffer.removeAll()
                return nil
            }
        } while (encodedByte & 0x80) != 0

        let remainingLength = value
        let headerSize = 1 + lengthByteCount
        let totalSize = headerSize + remainingLength
        guard bytes.count >= totalSize else { return nil } // need more data

        let payloadStart = bytes.index(start, offsetBy: headerSize)
        let payloadEnd = bytes.index(start, offsetBy: totalSize)
        let payload = bytes.subdata(in: payloadStart..<payloadEnd)

        buffer.removeSubrange(start..<payloadEnd)
        return MQTTRawPacket(typeByte: typeByte, payload: payload)
    }
}

enum MQTTDecode {
    /// Reads a length-prefixed UTF-8 string starting at `offset`, returns
    /// the string and the offset just past it.
    static func readString(_ data: Data, offset: Int) -> (String, Int)? {
        guard offset + 2 <= data.count else { return nil }
        let start = data.startIndex + offset
        let len = Int(data[start]) << 8 | Int(data[data.index(after: start)])
        let strStart = data.index(start, offsetBy: 2)
        guard offset + 2 + len <= data.count else { return nil }
        let strEnd = data.index(strStart, offsetBy: len)
        let str = String(data: data.subdata(in: strStart..<strEnd), encoding: .utf8) ?? ""
        return (str, offset + 2 + len)
    }

    /// Splits a PUBLISH packet payload into (topic, message body).
    static func parsePublish(_ payload: Data) -> (topic: String, body: Data)? {
        guard let (topic, next) = readString(payload, offset: 0) else { return nil }
        let bodyStart = payload.index(payload.startIndex, offsetBy: next)
        let body = payload.subdata(in: bodyStart..<payload.endIndex)
        return (topic, body)
    }
}
