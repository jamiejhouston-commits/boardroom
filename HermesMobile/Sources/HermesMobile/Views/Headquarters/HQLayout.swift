import SceneKit

/// The kinds of workspace on the HQ floor. Each maps to a distinct visual
/// treatment in `HQSceneBuilder` and a fixed anchor position.
enum HQOfficeArchetype: CaseIterable {
    case executive       // the CEO's raised, gold-lit power office
    case command         // the shared centerpiece (no seated agent in Slice 1)
    case researchLab     // bright, clean, glass
    case engineeringDen  // darker, screen-lit
}

/// One agent placed into a zone.
struct HQPlacement {
    let agent: OrgAgent
    let archetype: HQOfficeArchetype
    let anchor: SCNVector3
    let yaw: Float
}

/// Data-driven mapping of org agents → floor zones. Pure — unit-tested.
/// Slice 1 seats the CEO in the executive wing and the first two department
/// heads in the research + engineering pods (command center is the stage).
enum HQLayout {
    static func placements(for agents: [OrgAgent]) -> [HQPlacement] {
        var result: [HQPlacement] = []

        let ceo = agents.first { $0.tier == .ceo } ?? agents.first
        if let ceo {
            result.append(HQPlacement(agent: ceo,
                                      archetype: .executive,
                                      anchor: HQSceneBuilder.zoneAnchors[.executive]!,
                                      yaw: HQSceneBuilder.zoneYaw[.executive]!))
        }

        let deptArchetypes: [HQOfficeArchetype] = [.researchLab, .engineeringDen]
        let managers = agents.filter { $0.tier == .manager && $0.id != ceo?.id }
        for (index, manager) in managers.prefix(2).enumerated() {
            let archetype = deptArchetypes[index]
            result.append(HQPlacement(agent: manager,
                                      archetype: archetype,
                                      anchor: HQSceneBuilder.zoneAnchors[archetype]!,
                                      yaw: HQSceneBuilder.zoneYaw[archetype]!))
        }

        return result   // CEO + up to 2 managers = at most 3
    }
}
