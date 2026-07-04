import SceneKit

/// The kinds of workspace on the HQ floor. Each maps to a distinct visual
/// treatment in `HQSceneBuilder` and a fixed anchor position.
enum HQOfficeArchetype: CaseIterable {
    case executive        // the CEO's raised, gold-lit power office
    case command          // the shared centerpiece (no seated agent in Slice 1)
    case researchLab      // bright, clean, glass
    case engineeringDen   // darker, screen-lit
    case commandEast      // console post flanking the dais (east)
    case commandWest      // console post flanking the dais (west)
    case researchLab2     // second desk in the research pod
    case engineeringDen2  // second desk in the engineering pod
    case lounge           // the sofa corner by the mechs
}

/// One agent placed into a zone.
struct HQPlacement {
    let agent: OrgAgent
    let archetype: HQOfficeArchetype
    let anchor: SCNVector3
    let yaw: Float
}

/// Data-driven mapping of org agents → floor zones. Pure — unit-tested.
/// The CEO takes the executive wing and the first two department heads anchor
/// the research + engineering pods (unchanged invariants); the rest of the
/// staff fills the console posts, second pod desks, and the lounge — a floor
/// that reads as a working company, capped at 8 for the mobile GPU budget.
enum HQLayout {
    /// Hard population cap — each agent is a skinned USDZ character.
    static let maxAgents = 8

    /// Fill order for everyone after the CEO + the two pod leads.
    static let overflowSeats: [HQOfficeArchetype] = [
        .commandEast, .commandWest, .researchLab2, .engineeringDen2, .lounge,
    ]

    static func placements(for agents: [OrgAgent]) -> [HQPlacement] {
        var result: [HQPlacement] = []
        var seated = Set<String>()

        func seat(_ agent: OrgAgent, at archetype: HQOfficeArchetype) {
            guard let anchor = HQSceneBuilder.zoneAnchors[archetype],
                  let yaw = HQSceneBuilder.zoneYaw[archetype] else { return }
            result.append(HQPlacement(agent: agent, archetype: archetype,
                                      anchor: anchor, yaw: yaw))
            seated.insert(agent.id)
        }

        let ceo = agents.first { $0.tier == .ceo } ?? agents.first
        if let ceo { seat(ceo, at: .executive) }

        let deptArchetypes: [HQOfficeArchetype] = [.researchLab, .engineeringDen]
        let managers = agents.filter { $0.tier == .manager && $0.id != ceo?.id }
        for (index, manager) in managers.prefix(2).enumerated() {
            seat(manager, at: deptArchetypes[index])
        }

        // Everyone else — remaining managers first (org order), then the team.
        let rest = agents.filter { !seated.contains($0.id) }
        for (seatIndex, agent) in zip(overflowSeats.indices, rest) {
            if result.count >= maxAgents { break }
            seat(agent, at: overflowSeats[seatIndex])
        }

        return result   // ≤ maxAgents, CEO + pod leads always seated first
    }
}
