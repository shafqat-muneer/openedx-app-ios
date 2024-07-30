//
//  CourseScreensViewModel.swift
//  Course
//
//  Created by  Stepanok Ivan on 10.10.2022.
//

import Foundation
import SwiftUI
import Core
import Combine

public enum CourseTab: Int, CaseIterable, Identifiable {
    public var id: Int {
        rawValue
    }
    case course
    case videos
    case dates
    case discussion
    case handounds
}

extension CourseTab {
    public var title: String {
        switch self {
        case .course:
            return CourseLocalization.CourseContainer.home
        case .videos:
            return CourseLocalization.CourseContainer.videos
        case .dates:
            return CourseLocalization.CourseContainer.dates
        case .discussion:
            return CourseLocalization.CourseContainer.discussions
        case .handounds:
            return CourseLocalization.CourseContainer.handouts
        }
    }

    public var image: Image {
        switch self {
        case .course:
            return CoreAssets.home.swiftUIImage.renderingMode(.template)
        case .videos:
            return CoreAssets.videos.swiftUIImage.renderingMode(.template)
        case .dates:
            return CoreAssets.dates.swiftUIImage.renderingMode(.template)
        case .discussion:
            return  CoreAssets.discussions.swiftUIImage.renderingMode(.template)
        case .handounds:
            return CoreAssets.more.swiftUIImage.renderingMode(.template)
        }
    }
}

public class CourseContainerViewModel: BaseCourseViewModel {

    @Published public var selection: Int
    @Published var isShowProgress = true
    @Published var isShowRefresh = false
    @Published var courseStructure: CourseStructure?
    @Published var courseDeadlineInfo: CourseDateBanner?
    @Published var courseVideosStructure: CourseStructure?
    @Published var showError: Bool = false
    @Published var sequentialsDownloadState: [String: DownloadViewState] = [:]
    @Published private(set) var downloadableVerticals: Set<VerticalsDownloadState> = []
    @Published var continueWith: ContinueWith?
    @Published var userSettings: UserSettings?
    @Published var isInternetAvaliable: Bool = true
    @Published var dueDatesShifted: Bool = false
    @Published var shouldHideMenuBar: Bool = false
    @Published var updateCourseProgress: Bool = false
    
    let completionPublisher = NotificationCenter.default.publisher(for: .onblockCompletionRequested)

    var errorMessage: String? {
        didSet {
            withAnimation {
                showError = errorMessage != nil
            }
        }
    }
    
    @Published var shouldShowUpgradeButton: Bool = false
        
    var sku: String? {
        courseStructure?.sku
    }
    
    let router: CourseRouter
    let config: ConfigProtocol
    let connectivity: ConnectivityProtocol

    let isActive: Bool?
    let courseStart: Date?
    let courseEnd: Date?
    let enrollmentStart: Date?
    let enrollmentEnd: Date?
    private var lastVisitedBlockID: String?

    var courseDownloadTasks: [DownloadDataTask] = []
    private(set) var waitingDownloads: [CourseBlock]?

    private let interactor: CourseInteractorProtocol
    private let authInteractor: AuthInteractorProtocol
    let analytics: CourseAnalytics
    let coreAnalytics: CoreAnalytics
    private(set) var storage: CourseStorage
    private var courseID: String?
    let serverConfig: ServerConfigProtocol
    
    public init(
        interactor: CourseInteractorProtocol,
        authInteractor: AuthInteractorProtocol,
        router: CourseRouter,
        analytics: CourseAnalytics,
        config: ConfigProtocol,
        connectivity: ConnectivityProtocol,
        manager: DownloadManagerProtocol,
        storage: CourseStorage,
        isActive: Bool?,
        courseStart: Date?,
        courseEnd: Date?,
        enrollmentStart: Date?,
        enrollmentEnd: Date?,
        lastVisitedBlockID: String?,
        coreAnalytics: CoreAnalytics,
        selection: CourseTab = CourseTab.course,
        serverConfig: ServerConfigProtocol
    ) {
        self.interactor = interactor
        self.authInteractor = authInteractor
        self.router = router
        self.analytics = analytics
        self.config = config
        self.connectivity = connectivity
        self.isActive = isActive
        self.courseStart = courseStart
        self.courseEnd = courseEnd
        self.enrollmentStart = enrollmentStart
        self.enrollmentEnd = enrollmentEnd
        self.storage = storage
        self.userSettings = storage.userSettings
        self.isInternetAvaliable = connectivity.isInternetAvaliable
        self.lastVisitedBlockID = lastVisitedBlockID
        self.coreAnalytics = coreAnalytics
        self.selection = selection.rawValue
        self.serverConfig = serverConfig
        
        super.init(manager: manager)
        addObservers()
    }
    
    @MainActor
    func updateCourseIfNeeded(courseID: String) async {
        if updateCourseProgress {
            await getCourseBlocks(courseID: courseID, withProgress: false)
            await MainActor.run {
                updateCourseProgress = false
            }
        }
    }

    func openLastVisitedBlock() {
        guard let continueWith = continueWith,
              let courseStructure = courseStructure else { return }
        let chapter = courseStructure.childs[continueWith.chapterIndex]
        let sequential = chapter.childs[continueWith.sequentialIndex]
        let continueUnit = sequential.childs[continueWith.verticalIndex]
        
        var continueBlock: CourseBlock?
        continueUnit.childs.forEach { block in
            if block.id == continueWith.lastVisitedBlockId {
                continueBlock = block
            }
        }
        
        trackResumeCourseClicked(
            blockId: continueBlock?.id ?? ""
        )
        
        router.showCourseUnit(
            courseName: courseStructure.displayName,
            blockId: continueBlock?.id ?? "",
            courseID: courseStructure.id,
            verticalIndex: continueWith.verticalIndex,
            chapters: courseStructure.childs,
            chapterIndex: continueWith.chapterIndex,
            sequentialIndex: continueWith.sequentialIndex
        )
        
        self.lastVisitedBlockID = nil
    }
    
    @MainActor
    func reload(courseID: String) async {
        updateMenuBarVisibility()
        self.courseID = courseID
        await withTaskGroup(of: Void.self) {[weak self] group in
            guard let self = self else { return }
            group.addTask {
                await self.getCourseBlocks(courseID: courseID)
            }
            group.addTask {
                await self.getCourseDeadlineInfo(courseID: courseID, withProgress: false)
            }
        }
    }

    @MainActor
    func getCourseStructure(courseID: String) async throws -> CourseStructure? {
        if isInternetAvaliable {
            return try await interactor.getCourseBlocks(courseID: courseID)
        } else {
            return try await interactor.getLoadedCourseBlocks(courseID: courseID)
        }
    }
    
    @MainActor
    func updateMenuBarVisibility() {
        shouldHideMenuBar =
            courseStructure == nil ||
            courseStructure?.coursewareAccessDetails?.coursewareAccess?.hasAccess == false
    }
    
    @MainActor
    func getCourseBlocks(courseID: String, withProgress: Bool = true) async {
        guard let courseStart, courseStart < Date() else {
            isShowProgress = false
            isShowRefresh = false
            return
        }
        
        isShowProgress = withProgress
        isShowRefresh = !withProgress
        do {
            let courseStructure = try await getCourseStructure(courseID: courseID)
            await setDownloadsStates(courseStructure: courseStructure)
            self.courseStructure = courseStructure
            let type = type(for: courseStructure?.coursewareAccessDetails?.coursewareAccess)
            shouldShowUpgradeButton = type == nil 
            && courseStructure?.isUpgradeable ?? false
            && serverConfig.iapConfig.enabled
            
            updateMenuBarVisibility()

            if isInternetAvaliable {
                NotificationCenter.default.post(name: .getCourseDates, object: courseID)
                if let courseStructure {
                    try await getResumeBlock(
                        courseID: courseID,
                        courseStructure: courseStructure
                    )
                }
            }
            courseVideosStructure = interactor.getCourseVideoBlocks(fullStructure: courseStructure!)
            isShowProgress = false
            isShowRefresh = false
            
        } catch {
            isShowProgress = false
            isShowRefresh = false
            shouldShowUpgradeButton = false
            if courseStructure?.coursewareAccessDetails?.coursewareAccess?.errorCode == .unknown {
                courseStructure = nil
                courseVideosStructure = nil
            }
        }
    }
    
    @MainActor
    func getCourseDeadlineInfo(courseID: String, withProgress: Bool = true) async {
        guard let courseStart, courseStart < Date() else { return }
        do {
            let courseDeadlineInfo = try await interactor.getCourseDeadlineInfo(courseID: courseID)
            withAnimation {
                self.courseDeadlineInfo = courseDeadlineInfo
            }
        } catch let error {
            debugLog(error.localizedDescription)
        }
    }

    @MainActor
    func shiftDueDates(courseID: String, withProgress: Bool = true, screen: DatesStatusInfoScreen, type: String) async {
        isShowProgress = withProgress
        isShowRefresh = !withProgress
        
        do {
            try await interactor.shiftDueDates(courseID: courseID)
            NotificationCenter.default.post(name: .shiftCourseDates, object: courseID)
            isShowProgress = false
            isShowRefresh = false
            
            analytics.plsSuccessEvent(
                .plsShiftDatesSuccess,
                bivalue: .plsShiftDatesSuccess,
                courseID: courseID,
                screenName: screen.rawValue,
                type: type,
                success: true
            )
            
        } catch let error {
            isShowProgress = false
            isShowRefresh = false
            analytics.plsSuccessEvent(
                .plsShiftDatesSuccess,
                bivalue: .plsShiftDatesSuccess,
                courseID: courseID,
                screenName: screen.rawValue,
                type: type,
                success: false
            )
            if error.isInternetError || error is NoCachedDataError {
                errorMessage = CoreLocalization.Error.slowOrNoInternetConnection
            } else {
                errorMessage = CoreLocalization.Error.unknownError
            }
        }
    }
    
    private func date(from stringDate: String?) -> Date? {
        guard let stringDate else { return nil }
        
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX") // set locale to reliable US_POSIX
        dateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        return dateFormatter.date(from: stringDate)
    }
    
    func type(for access: CoursewareAccess?) -> CourseAccessErrorHelperType? {
        guard let access, !access.hasAccess else { return nil }
        
        if let courseEnd, courseEnd.isInPast() {
            if courseStructure?.isUpgradeable == true {
                guard let courseStructure, let courseID else { return nil }
                return .upgradeable(
                    date: courseEnd,
                    sku: courseStructure.sku ?? "",
                    courseID: courseID,
                    pacing: courseStructure.isSelfPaced ? Pacing.selfPace.rawValue : Pacing.instructor.rawValue,
                    screen: .courseDashboard,
                    lmsPrice: courseStructure.lmsPrice ?? .zero
                )
            } else {
                return .isEndDateOld(date: courseEnd)
            }
        } else {
            guard let errorCode = access.errorCode else { return nil }
            
            switch errorCode {
            case .notStarted:
                return .startDateError(date: courseStart)
            case .auditExpired:
                guard
                    let courseStructure,
                    let courseID,
                    let dateString = courseStructure.coursewareAccessDetails?.auditAccessExpires,
                    let date = date(from: dateString)
                else { return nil }
                return .auditExpired(
                    date: date,
                    sku: courseStructure.sku ?? "",
                    courseID: courseID,
                    pacing: courseStructure.isSelfPaced ? Pacing.selfPace.rawValue : Pacing.instructor.rawValue,
                    screen: .courseDashboard,
                    lmsPrice: courseStructure.lmsPrice ?? .zero
                )
            
            default:
                return nil
            }
        }
    }
    
    func update(downloadQuality: DownloadQuality) {
        storage.userSettings?.downloadQuality = downloadQuality
        userSettings = storage.userSettings
    }

    @MainActor
    func tryToRefreshCookies() async {
        try? await authInteractor.getCookies(force: false)
    }
    
    @MainActor
    private func getResumeBlock(courseID: String, courseStructure: CourseStructure) async throws {
        if let lastVisitedBlockID {
            self.continueWith = findContinueVertical(
                blockID: lastVisitedBlockID,
                courseStructure: courseStructure
            )
            openLastVisitedBlock()
        } else {
            let result = try await interactor.resumeBlock(courseID: courseID)
            withAnimation {
                self.continueWith = findContinueVertical(
                    blockID: result.blockID,
                    courseStructure: courseStructure
                )
            }
        }
    }

    @MainActor
    func onDownloadViewTap(chapter: CourseChapter, state: DownloadViewState) async {
        let blocks = chapter.childs
            .flatMap { $0.childs }
            .flatMap { $0.childs }
            .filter { $0.isDownloadable }

        if state == .available, isShowedAllowLargeDownloadAlert(blocks: blocks) {
            return
        }

        if state == .available {
            analytics.bulkDownloadVideosSection(
                courseID: courseStructure?.id ?? "",
                sectionID: chapter.id,
                videos: blocks.count
            )
        } else if state == .finished {
            analytics.bulkDeleteVideosSection(
                courseID: courseStructure?.id ?? "",
                sectionId: chapter.id,
                videos: blocks.count
            )
        }

        await download(state: state, blocks: blocks)
    }

    func showPaymentsInfo() {
        guard let structure = courseStructure,
              let sku = courseStructure?.sku,
              let lmsPrice = courseStructure?.lmsPrice
        else { return }
        
        Task {@MainActor in
            await router.showUpgradeInfo(
                productName: structure.displayName,
                message: "",
                sku: sku,
                courseID: structure.id,
                screen: .courseDashboard,
                pacing: structure.isSelfPaced ? Pacing.selfPace.rawValue : Pacing.instructor.rawValue,
                lmsPrice: lmsPrice
            )
        }
    }
    
    func verticalsBlocksDownloadable(by courseSequential: CourseSequential) -> [CourseBlock] {
        let verticals = downloadableVerticals.filter { verticalState in
            courseSequential.childs.contains(where: { item in
                return verticalState.vertical.id == item.id
            })
        }
        return verticals.flatMap { $0.vertical.childs.filter { $0.isDownloadable } }
    }

    func getTasks(sequential: CourseSequential) -> [DownloadDataTask] {
        let blocks = verticalsBlocksDownloadable(by: sequential)
        let tasks = blocks.compactMap { block in
            courseDownloadTasks.first(where: { $0.id ==  block.id})
        }
        return tasks
    }

    func continueDownload() async {
        guard let blocks = waitingDownloads else {
            return
        }
        do {
            try await manager.addToDownloadQueue(blocks: blocks)
        } catch let error {
            if error is NoWiFiError {
                await MainActor.run {
                    errorMessage = CoreLocalization.Error.wifi
                }
            }
        }
    }

    func trackSelectedTab(
        selection: CourseTab,
        courseId: String,
        courseName: String
    ) {
        switch selection {
        case .course:
            analytics.courseOutlineCourseTabClicked(courseId: courseId, courseName: courseName)
        case .videos:
            analytics.courseOutlineVideosTabClicked(courseId: courseId, courseName: courseName)
        case .dates:
            analytics.courseOutlineDatesTabClicked(courseId: courseId, courseName: courseName)
        case .discussion:
            analytics.courseOutlineDiscussionTabClicked(courseId: courseId, courseName: courseName)
        case .handounds:
            analytics.courseOutlineHandoutsTabClicked(courseId: courseId, courseName: courseName)
        }
    }

    func trackVerticalClicked(
        courseId: String,
        courseName: String,
        vertical: CourseVertical
    ) {
        analytics.verticalClicked(
            courseId: courseId,
            courseName: courseName,
            blockId: vertical.blockId,
            blockName: vertical.displayName
        )
    }
    
    func trackViewCertificateClicked(courseID: String) {
        analytics.trackCourseEvent(
            .courseViewCertificateClicked,
            biValue: .courseViewCertificateClicked,
            courseID: courseID
        )
    }

    func trackSequentialClicked(_ sequential: CourseSequential) {
        guard let course = courseStructure else { return }
        analytics.sequentialClicked(
            courseId: course.id,
            courseName: course.displayName,
            blockId: sequential.blockId,
            blockName: sequential.displayName
        )
    }
    
    func trackResumeCourseClicked(blockId: String) {
        guard let course = courseStructure else { return }
        analytics.resumeCourseClicked(
            courseId: course.id,
            courseName: course.displayName,
            blockId: blockId
        )
    }

    func completeBlock(
        chapterID: String,
        sequentialID: String,
        verticalID: String,
        blockID: String
    ) {
        guard let chapterIndex = courseStructure?
            .childs.firstIndex(where: { $0.id == chapterID }) else {
            return
        }
        guard let sequentialIndex = courseStructure?
            .childs[chapterIndex]
            .childs.firstIndex(where: { $0.id == sequentialID }) else {
            return
        }

        guard let verticalIndex = courseStructure?
            .childs[chapterIndex]
            .childs[sequentialIndex]
            .childs.firstIndex(where: { $0.id == verticalID }) else {
            return
        }

        guard let blockIndex = courseStructure?
            .childs[chapterIndex]
            .childs[sequentialIndex]
            .childs[verticalIndex]
            .childs.firstIndex(where: { $0.id == blockID }) else {
            return
        }

        courseStructure?
            .childs[chapterIndex]
            .childs[sequentialIndex]
            .childs[verticalIndex]
            .childs[blockIndex].completion = 1
        courseStructure.map {
            courseVideosStructure = interactor.getCourseVideoBlocks(fullStructure: $0)
        }
    }

    func hasVideoForDowbloads() -> Bool {
        guard let courseVideosStructure = courseVideosStructure else {
            return false
        }
        return courseVideosStructure.childs
            .flatMap { $0.childs }
            .contains(where: { $0.isDownloadable })
    }

    func isAllDownloading() -> Bool {
        let totalCount = downloadableVerticals.count
        let downloadingCount = downloadableVerticals.filter { $0.state == .downloading }.count
        let finishedCount = downloadableVerticals.filter { $0.state == .finished }.count
        if finishedCount == totalCount { return false }
        return totalCount - finishedCount == downloadingCount
    }

    @MainActor
    func download(state: DownloadViewState, blocks: [CourseBlock]) async {
        do {
            switch state {
            case .available:
                try await manager.addToDownloadQueue(blocks: blocks)
            case .downloading:
                try await manager.cancelDownloading(courseId: courseStructure?.id ?? "", blocks: blocks)
            case .finished:
                if let courseID {
                    await manager.delete(blocks: blocks, courseId: courseID)
                }
            }
        } catch let error {
            if error is NoWiFiError {
                errorMessage = CoreLocalization.Error.wifi
            }
        }
    }

    @MainActor
    func isShowedAllowLargeDownloadAlert(blocks: [CourseBlock]) -> Bool {
        waitingDownloads = nil
        if storage.allowedDownloadLargeFile == false, manager.isLargeVideosSize(blocks: blocks) {
            waitingDownloads = blocks
            router.presentAlert(
                alertTitle: CourseLocalization.Download.download,
                alertMessage: CourseLocalization.Download.downloadLargeFileMessage,
                positiveAction: CourseLocalization.Alert.accept,
                onCloseTapped: {
                    self.router.dismiss(animated: true)
                },
                okTapped: {
                    Task {
                        await self.continueDownload()
                    }
                    self.router.dismiss(animated: true)
                },
                type: .default(positiveAction: CourseLocalization.Alert.accept, image: nil)
            )
            return true
        }
        return false
    }

    @MainActor
    func downloadableBlocks(from sequential: CourseSequential) -> [CourseBlock] {
        let verticals = sequential.childs
        let blocks = verticals
            .flatMap { $0.childs }
            .filter { $0.isDownloadable }
        return blocks
    }

    @MainActor
    func setDownloadsStates(courseStructure: CourseStructure?) async {
        guard let course = courseStructure else { return }
        courseDownloadTasks = await manager.getDownloadTasksForCourse(course.id)
        downloadableVerticals = []
        var sequentialsStates: [String: DownloadViewState] = [:]
        for chapter in course.childs {
            for sequential in chapter.childs where sequential.isDownloadable {
                var sequentialsChilds: [DownloadViewState] = []
                for vertical in sequential.childs where vertical.isDownloadable {
                    var verticalsChilds: [DownloadViewState] = []
                    for block in vertical.childs where block.isDownloadable {
                        if let download = courseDownloadTasks.first(where: { $0.blockId == block.id }) {
                            switch download.state {
                            case .waiting, .inProgress:
                                sequentialsChilds.append(.downloading)
                                verticalsChilds.append(.downloading)
                            case .finished:
                                sequentialsChilds.append(.finished)
                                verticalsChilds.append(.finished)
                            }
                        } else {
                            sequentialsChilds.append(.available)
                            verticalsChilds.append(.available)
                        }
                    }
                    if verticalsChilds.first(where: { $0 == .downloading }) != nil {
                        downloadableVerticals.insert(.init(vertical: vertical, state: .downloading))
                    } else if verticalsChilds.allSatisfy({ $0 == .finished }) {
                        downloadableVerticals.insert(.init(vertical: vertical, state: .finished))
                    } else {
                        downloadableVerticals.insert(.init(vertical: vertical, state: .available))
                    }
                }
                if sequentialsChilds.first(where: { $0 == .downloading }) != nil {
                    sequentialsStates[sequential.id] = .downloading
                } else if sequentialsChilds.allSatisfy({ $0 == .finished }) {
                    sequentialsStates[sequential.id] = .finished
                } else {
                    sequentialsStates[sequential.id] = .available
                }
            }
            self.sequentialsDownloadState = sequentialsStates
        }
    }
    
    private func findContinueVertical(blockID: String, courseStructure: CourseStructure) -> ContinueWith? {
        for chapterIndex in courseStructure.childs.indices {
            let chapter = courseStructure.childs[chapterIndex]
            for sequentialIndex in chapter.childs.indices {
                let sequential = chapter.childs[sequentialIndex]
                for verticalIndex in sequential.childs.indices {
                    let vertical = sequential.childs[verticalIndex]
                    for block in vertical.childs where block.id == blockID {
                        return ContinueWith(
                            chapterIndex: chapterIndex,
                            sequentialIndex: sequentialIndex,
                            verticalIndex: verticalIndex,
                            lastVisitedBlockId: block.id
                        )
                    }
                }
            }
        }
        return nil
    }

    private func addObservers() {
        manager.eventPublisher()
            .sink { [weak self] state in
                guard let self else { return }
                if case .progress = state { return }
                debugLog(state, "--- state ---")
                Task {
                    await self.setDownloadsStates(courseStructure: self.courseStructure)
                }
            }
            .store(in: &cancellables)

        connectivity.internetReachableSubject
            .sink { [weak self] _ in
            guard let self else { return }
                self.isInternetAvaliable = self.connectivity.isInternetAvaliable
        }
        .store(in: &cancellables)
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleShiftDueDates),
            name: .shiftCourseDates, object: nil
        )
        
        NotificationCenter.default
            .publisher(for: .courseUpgradeCompletionNotification)
            .sink { [weak self] _ in
                guard let self = self else { return }
                DispatchQueue.main.async {
                    Task {
                        if let courseID = self.courseID {
                            await self.reload(courseID: courseID)
                        }
                    }
                }
            }
            .store(in: &cancellables)
        
        completionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                updateCourseProgress = true
            }
            .store(in: &cancellables)
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}

extension CourseContainerViewModel {
    @objc private func handleShiftDueDates(_ notification: Notification) {
        if let courseID = notification.object as? String {
            Task {
                await withTaskGroup(of: Void.self) { group in
                    group.addTask {
                        await self.getCourseBlocks(courseID: courseID, withProgress: true)
                    }
                    group.addTask {
                        await self.getCourseDeadlineInfo(courseID: courseID, withProgress: true)
                    }
                    await MainActor.run { [weak self] in
                        self?.dueDatesShifted = true
                    }
                }
            }
        }
    }
    
    func resetDueDatesShiftedFlag() {
        dueDatesShifted = false
    }
}

struct VerticalsDownloadState: Hashable {
    let vertical: CourseVertical
    let state: DownloadViewState

    var downloadableBlocks: [CourseBlock] {
        vertical.childs.filter { $0.isDownloadable }
    }
}
