import Foundation

enum OpenLiftStateResolver {
    static func preferredTemplate(
        templates: [CycleTemplate],
        sessions: [Session],
        latestExport: SessionExportService.ExportPayload?,
        preferredTemplateId: UUID?,
        preferredTemplateName: String?
    ) -> CycleTemplate? {
        let recentCycleName = BootstrapDataService.recentCycleName(
            sessions: sessions,
            latestExport: latestExport
        )

        if let recentCycleName,
           let recent = BootstrapDataService.matchingTemplate(named: recentCycleName, in: templates) {
            return recent
        }
        if let preferredTemplateId,
           let preferred = templates.first(where: { $0.id == preferredTemplateId }) {
            return preferred
        }
        if let preferredTemplateName,
           let preferred = templates.first(where: { $0.name.caseInsensitiveCompare(preferredTemplateName) == .orderedSame }) {
            return preferred
        }
        if let fb2d = templates.first(where: { $0.name.caseInsensitiveCompare("FB 2D") == .orderedSame }) {
            return fb2d
        }
        return templates.first
    }

    static func activeCycle(
        activeCycles: [ActiveCycleInstance],
        templates: [CycleTemplate],
        sessions: [Session],
        latestExport: SessionExportService.ExportPayload?,
        preferredTemplateId: UUID?
    ) -> ActiveCycleInstance? {
        if let preferredTemplateId,
           let preferred = activeCycles.first(where: { $0.templateId == preferredTemplateId }) {
            return preferred
        }

        if let recentCycleName = BootstrapDataService.recentCycleName(
            sessions: sessions,
            latestExport: latestExport
        ),
           let recentTemplate = BootstrapDataService.matchingTemplate(named: recentCycleName, in: templates),
           let recentCycle = activeCycles.first(where: { $0.templateId == recentTemplate.id }) {
            return recentCycle
        }

        if let latestDraft = sessions
            .filter({ $0.status == .draft })
            .sorted(by: { $0.createdAt > $1.createdAt })
            .first,
           let draftCycle = activeCycles.first(where: { $0.id == latestDraft.cycleInstanceId }) {
            return draftCycle
        }

        if let latestCompleted = sessions
            .filter({ $0.status == .completed })
            .sorted(by: { ($0.finishedAt ?? $0.createdAt) > ($1.finishedAt ?? $1.createdAt) })
            .first,
           let completedCycle = activeCycles.first(where: { $0.id == latestCompleted.cycleInstanceId }) {
            return completedCycle
        }

        return activeCycles.first
    }

    static func activeTemplate(
        activeCycles: [ActiveCycleInstance],
        templates: [CycleTemplate],
        sessions: [Session],
        latestExport: SessionExportService.ExportPayload?,
        preferredTemplateId: UUID?
    ) -> CycleTemplate? {
        guard let cycle = activeCycle(
            activeCycles: activeCycles,
            templates: templates,
            sessions: sessions,
            latestExport: latestExport,
            preferredTemplateId: preferredTemplateId
        ) else {
            return nil
        }
        return templates.first(where: { $0.id == cycle.templateId })
    }

    static func preferredDraftSession(
        sessions: [Session],
        activeCycle: ActiveCycleInstance?
    ) -> Session? {
        let drafts = sessions
            .filter { $0.status == .draft }
            .sorted { $0.createdAt > $1.createdAt }

        guard let activeCycle else {
            return drafts.first
        }

        return drafts.first(where: {
            $0.cycleInstanceId == activeCycle.id && $0.cycleDayIndex == activeCycle.currentDayIndex
        }) ?? drafts.first(where: {
            $0.cycleInstanceId == activeCycle.id
        }) ?? drafts.first
    }

    static func draftSessionIds(
        sessions: [Session],
        forCycleId cycleId: UUID
    ) -> Set<UUID> {
        Set(
            sessions
                .filter { $0.status == .draft && $0.cycleInstanceId == cycleId }
                .map(\.id)
        )
    }

    static func cycleName(
        for session: Session,
        activeCycles: [ActiveCycleInstance],
        templates: [CycleTemplate]
    ) -> String {
        if let snapshot = session.cycleNameSnapshot, !snapshot.isEmpty {
            return snapshot
        }
        guard let cycle = activeCycles.first(where: { $0.id == session.cycleInstanceId }) else {
            return "Unknown Cycle"
        }
        return templates.first(where: { $0.id == cycle.templateId })?.name ?? "Unknown Cycle"
    }

    static func dayLabel(
        for session: Session,
        activeCycles: [ActiveCycleInstance],
        templates: [CycleTemplate]
    ) -> String {
        if let snapshot = session.dayLabelSnapshot, !snapshot.isEmpty {
            return snapshot
        }
        guard let cycle = activeCycles.first(where: { $0.id == session.cycleInstanceId }),
              let template = templates.first(where: { $0.id == cycle.templateId }) else {
            return "Day \(session.cycleDayIndex + 1)"
        }
        let orderedDays = CycleOrdering.sortedDays(template.days)
        guard session.cycleDayIndex >= 0, session.cycleDayIndex < orderedDays.count else {
            return "Day \(session.cycleDayIndex + 1)"
        }
        return orderedDays[session.cycleDayIndex].label
    }

    static func mostRecentCompletedSession(
        sessions: [Session],
        activeCycles: [ActiveCycleInstance],
        templates: [CycleTemplate],
        templateName: String,
        cycleDayIndex: Int
    ) -> Session? {
        let target = canonical(templateName)
        return sessions
            .filter { session in
                session.status == .completed &&
                session.cycleDayIndex == cycleDayIndex &&
                canonical(cycleName(for: session, activeCycles: activeCycles, templates: templates)) == target
            }
            .sorted { ($0.finishedAt ?? $0.createdAt) > ($1.finishedAt ?? $1.createdAt) }
            .first
    }

    private static func canonical(_ text: String) -> String {
        text.lowercased().unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }
}
