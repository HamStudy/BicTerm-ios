import Foundation

public struct AgentConnectionInfo: Decodable, Equatable, Sendable {
    public let derpMap: DERPMap
    public let derpForceWebSockets: Bool
    public let disableDirectConnections: Bool
    public let hostnameSuffix: String?

    private enum CodingKeys: String, CodingKey {
        case derpMap = "derp_map"
        case derpForceWebSockets = "derp_force_websockets"
        case disableDirectConnections = "disable_direct_connections"
        case hostnameSuffix = "hostname_suffix"
    }
}

public struct DERPMap: Decodable, Equatable, Sendable {
    public let regions: [String: DERPRegion]
    public let omitDefaultRegions: Bool

    private enum CodingKeys: String, CodingKey {
        case regions = "Regions"
        case omitDefaultRegions
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        regions = try container.decode([String: DERPRegion].self, forKey: .regions)
        omitDefaultRegions = try container.decodeIfPresent(Bool.self, forKey: .omitDefaultRegions) ?? false
    }
}

public struct DERPRegion: Decodable, Equatable, Sendable {
    public let regionID: Int
    public let regionCode: String
    public let regionName: String
    public let avoid: Bool
    public let nodes: [DERPNode]

    private enum CodingKeys: String, CodingKey {
        case regionID = "RegionID"
        case regionCode = "RegionCode"
        case regionName = "RegionName"
        case avoid = "Avoid"
        case nodes = "Nodes"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        regionID = try container.decode(Int.self, forKey: .regionID)
        regionCode = try container.decode(String.self, forKey: .regionCode)
        regionName = try container.decode(String.self, forKey: .regionName)
        avoid = try container.decodeIfPresent(Bool.self, forKey: .avoid) ?? false
        nodes = try container.decode([DERPNode].self, forKey: .nodes)
    }
}

public struct DERPNode: Decodable, Equatable, Sendable {
    public let name: String
    public let regionID: Int
    public let hostName: String
    public let ipv4: String?
    public let ipv6: String?
    public let stunPort: Int
    public let derpPort: Int
    public let insecureForTests: Bool
    public let forceHTTP: Bool

    private enum CodingKeys: String, CodingKey {
        case name = "Name"
        case regionID = "RegionID"
        case hostName = "HostName"
        case ipv4 = "IPv4"
        case ipv6 = "IPv6"
        case stunPort = "STUNPort"
        case derpPort = "DERPPort"
        case insecureForTests = "InsecureForTests"
        case forceHTTP = "ForceHTTP"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        regionID = try container.decode(Int.self, forKey: .regionID)
        hostName = try container.decode(String.self, forKey: .hostName)
        ipv4 = try container.decodeIfPresent(String.self, forKey: .ipv4)
        ipv6 = try container.decodeIfPresent(String.self, forKey: .ipv6)
        stunPort = try container.decodeIfPresent(Int.self, forKey: .stunPort) ?? 0
        derpPort = try container.decodeIfPresent(Int.self, forKey: .derpPort) ?? 0
        insecureForTests = try container.decodeIfPresent(Bool.self, forKey: .insecureForTests) ?? false
        forceHTTP = try container.decodeIfPresent(Bool.self, forKey: .forceHTTP) ?? false
    }
}
