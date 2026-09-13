import Foundation

enum AppRuntime {
    static let isUITesting = ProcessInfo.processInfo.arguments.contains("OPENLIFT_UI_TESTING")
    static let shouldImportAvailableWorkoutExports = ProcessInfo.processInfo.arguments.contains(
        "OPENLIFT_IMPORT_AVAILABLE_WORKOUTS"
    )
    static let shouldPrepareAdaptiveRollout = ProcessInfo.processInfo.arguments.contains(
        "OPENLIFT_PREPARE_ADAPTIVE_ROLLOUT"
    )
    static let shouldPreparePushPullRollout = ProcessInfo.processInfo.arguments.contains(
        "OPENLIFT_PREPARE_PUSH_PULL_ROLLOUT"
    )
    static let shouldPrepareClusteredProgramRollout = ProcessInfo.processInfo.arguments.contains(
        "OPENLIFT_PREPARE_CLUSTERED_PROGRAM_ROLLOUT"
    )
    static let shouldPrepareSeptember2026ClusterRevision = ProcessInfo.processInfo.arguments.contains(
        "OPENLIFT_REVISE_CLUSTERED_PROGRAM_2026_09_06"
    )
    static let september2026ClusterRevisionBackupIsConfirmed = ProcessInfo.processInfo.arguments.contains(
        "OPENLIFT_CLUSTERED_REVISION_BACKUP_CONFIRMED"
    )
    static let shouldPrepareSeatedShrugClusterRevision = ProcessInfo.processInfo.arguments.contains(
        "OPENLIFT_ADD_CLUSTERED_SHRUGS_2026_09_08"
    )
    static let seatedShrugRevisionBackupIsConfirmed = ProcessInfo.processInfo.arguments.contains(
        "OPENLIFT_CLUSTERED_SHRUGS_BACKUP_CONFIRMED"
    )
    static let shouldSwapClusterSquats = ProcessInfo.processInfo.arguments.contains(
        "OPENLIFT_SWAP_CLUSTERED_SQUATS_2026_09_08"
    )
    static let shouldAuditClusterSquatSwap = ProcessInfo.processInfo.arguments.contains(
        "OPENLIFT_AUDIT_CLUSTERED_SQUAT_SWAP"
    )
    static let shouldAuditSeatedShrugRevision = ProcessInfo.processInfo.arguments.contains(
        "OPENLIFT_AUDIT_CLUSTERED_SHRUGS"
    )
    static let isSeatedShrugActivationUITesting = ProcessInfo.processInfo.arguments.contains(
        "OPENLIFT_UI_TESTING_SHRUG_ACTIVATION"
    )
    static let isSideDeltActivationUITesting = ProcessInfo.processInfo.arguments.contains("OPENLIFT_UI_TESTING_SIDE_DELT_ACTIVATION")
    static let shouldAuditSideDeltRevision = ProcessInfo.processInfo.arguments.contains("OPENLIFT_AUDIT_CLUSTERED_SIDE_DELT")
    static let shouldReorderClusteredSideDelts = ProcessInfo.processInfo.arguments.contains("OPENLIFT_REORDER_CLUSTERED_SIDE_DELTS_2026_09_12")
    static let shouldAddClusteredSideDelt = ProcessInfo.processInfo.arguments.contains("OPENLIFT_ADD_CLUSTERED_SIDE_DELT_2026_09_12")
    static let clusteredDraftBackupIsConfirmed = ProcessInfo.processInfo.arguments.contains(
        "OPENLIFT_CLUSTERED_DRAFT_BACKUP_CONFIRMED"
    )
    static let archivedPushPullDraftsAreConfirmed = ProcessInfo.processInfo.arguments.contains(
        "OPENLIFT_ARCHIVED_PUSH_PULL_DRAFTS_CONFIRMED"
    )
    static let shouldRepairJuly27AdaptiveInclineCurl = ProcessInfo.processInfo.arguments.contains(
        "OPENLIFT_REPAIR_2026_07_27_ADAPTIVE_INCLINE_CURL"
    )
    static let july27AdaptiveInclineCurlBackupIsConfirmed = ProcessInfo.processInfo.arguments.contains(
        "OPENLIFT_2026_07_27_ADAPTIVE_INCLINE_CURL_BACKUP_CONFIRMED"
    )
    static let shouldDisableGluteProgramming = ProcessInfo.processInfo.arguments.contains(
        "OPENLIFT_DISABLE_GLUTE_PROGRAMMING"
    )
    static let isAdaptiveWorkflowUITesting = ProcessInfo.processInfo.arguments.contains(
        "OPENLIFT_UI_TESTING_ADAPTIVE_WORKFLOW"
    )
    static let isAdaptiveHistoryUITesting = ProcessInfo.processInfo.arguments.contains(
        "OPENLIFT_UI_TESTING_ADAPTIVE_HISTORY"
    )

    static func prepareForUITesting() {
        // This disk-backed fixture reuses a store across launches, so preserve
        // its activation preferences just as a normal app launch does.
        guard isUITesting, !isSideDeltActivationUITesting else { return }
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "openlift.lastActivatedTemplateId")
        defaults.removeObject(forKey: "openlift.lastActivatedTemplateName")
    }
}
