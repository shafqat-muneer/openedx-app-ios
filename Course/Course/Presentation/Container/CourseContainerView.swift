//
//  CourseScreensView.swift
//  Course
//
//  Created by  Stepanok Ivan on 10.10.2022.
//

import SwiftUI
import Core
import Discussion
import Swinject
import Theme

public struct CourseContainerView: View {
    @ObservedObject
    public var viewModel: CourseContainerViewModel
    @ObservedObject
    public var courseDatesViewModel: CourseDatesViewModel
    @State private var isAnimatingForTap: Bool = false
    public var courseID: String
    private var title: String
    @State private var ignoreOffset: Bool = false
    @State private var coordinate: CGFloat = .zero
    @State private var lastCoordinate: CGFloat = .zero
    @State private var collapsed: Bool = false
    @State private var viewHeight: CGFloat = .zero
    @Environment(\.isHorizontal) private var isHorizontal
    @Namespace private var animationNamespace
    
    private var idiom: UIUserInterfaceIdiom { UIDevice.current.userInterfaceIdiom }
    private let coordinateBoundaryLower: CGFloat = -115
    private let courseRawImage: String?
    private let org: String?
    private let coursewareAccess: CoursewareAccess?
    private var coordinateBoundaryHigher: CGFloat {
        let topInset = UIApplication.shared.windowInsets.top
        guard topInset > 0 else {
            return 40
        }
        
        return topInset
    }
    
    private struct GeometryName {
        static let backButton = "backButton"
        static let topTabBar = "topTabBar"
        static let blurSecondaryBg = "blurSecondaryBg"
        static let blurPrimaryBg = "blurPrimaryBg"
        static let blurBg = "blurBg"
    }
    
    public init(
        viewModel: CourseContainerViewModel,
        courseDatesViewModel: CourseDatesViewModel,
        courseID: String,
        title: String,
        org: String?,
        courseRawImage: String?,
        coursewareAccess: CoursewareAccess?
    ) {
        self.viewModel = viewModel
        self.courseID = courseID
        self.title = title
        self.courseDatesViewModel = courseDatesViewModel
        self.courseRawImage = courseRawImage
        self.org = org
        self.coursewareAccess = coursewareAccess
        Task {
            await viewModel.reload(courseID: courseID)
        }
    }
    
    public var body: some View {
        ZStack(alignment: .top) {
            content
        }
        .navigationBarHidden(true)
        .navigationBarBackButtonHidden(true)
        .navigationTitle(title)
        .onChange(of: viewModel.selection, perform: didSelect)
        .onChange(of: coordinate, perform: collapseHeader)
        .background(Theme.Colors.background)
    }
    
    @ViewBuilder
    private var content: some View {
        if viewModel.courseStart != nil {
            ZStack(alignment: .top) {
                tabs
                GeometryReader { proxy in
                    VStack(spacing: 0) {
                        CourseHeaderView(
                            viewModel: viewModel,
                            title: title,
                            org: org,
                            collapsed: $collapsed,
                            containerWidth: proxy.size.width,
                            animationNamespace: animationNamespace,
                            isAnimatingForTap: $isAnimatingForTap,
                            courseRawImage: courseRawImage,
                            upgradeAction: {
                                viewModel.showPaymentsInfo()
                            }
                        )
                    }
                    .offset(
                        y: ignoreOffset
                        ? (collapsed ? coordinateBoundaryLower : .zero)
                        : ((coordinateBoundaryLower...coordinateBoundaryHigher).contains(coordinate)
                           ? coordinate
                           : (collapsed ? coordinateBoundaryLower : .zero))
                    )
                    backButton(containerWidth: proxy.size.width)
                }
            }
            .ignoresSafeArea(edges: idiom == .pad ? .leading : .top)
            .onAppear {
                self.collapsed = isHorizontal
            }
        }
        
        switch courseDatesViewModel.eventState {
        case .removedCalendar:
            showDatesSuccessView(
                title: CourseLocalization.CourseDates.calendarEvents,
                message: CourseLocalization.CourseDates.calendarEventsRemoved
            )
        case .updatedCalendar:
            showDatesSuccessView(
                title: CourseLocalization.CourseDates.calendarEvents,
                message: CourseLocalization.CourseDates.calendarEventsUpdated
            )
        default:
            EmptyView()
        }
    }
    
    private func showDatesSuccessView(title: String, message: String) -> some View {
        return DatesSuccessView(
            title: title,
            message: message
        ) {
            courseDatesViewModel.resetEventState()
        }
    }
    
    private func backButton(containerWidth: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            if !collapsed {
                HStack {
                    ZStack(alignment: .bottom) {
                        VisualEffectView(effect: UIBlurEffect(style: .regular))
                            .clipShape(Circle())
                        BackNavigationButton(
                            color: Theme.Colors.textPrimary,
                            action: {
                                viewModel.router.back()
                            }
                        )
                        .backViewStyle()
                        .matchedGeometryEffect(id: GeometryName.backButton, in: animationNamespace)
                        .offset(y: 7)
                    }
                    .frame(width: 30, height: 30)
                    .padding(.vertical, 8)
                    .padding(.leading, 12)
                    .padding(.top, idiom == .pad ? 0 : 55)
                    Spacer()
                }
            }
        }
    }
    
    private var actualAccess: CoursewareAccess? {
        viewModel.courseStructure?.coursewareAccessDetails?.coursewareAccess ?? coursewareAccess
    }
    
    private var tabs: some View {
        TabView(selection: $viewModel.selection) {
            if let courseStart = viewModel.courseStart, courseStart > Date() {
                UpgradeCourseView(
                    type: viewModel.type(for: actualAccess) ?? .startDateError(date: courseStart),
                    coordinate: $coordinate,
                    collapsed: $collapsed,
                    viewHeight: $viewHeight,
                    shouldShowUpgradeButton: $viewModel.shouldShowUpgradeButton,
                    shouldHideMenuBar: $viewModel.shouldHideMenuBar,
                    backAction: {
                        viewModel.router.back()
                    },
                    findAction: {
                        viewModel.router.backToRoot(animated: true)
                        viewModel.router.showTabScreen(tab: .discovery)
                    }
                )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onAppear {
                        ignoreOffset = true
                    }
            } else {
                if let type = viewModel.type(for: actualAccess) {
                    UpgradeCourseView(
                        type: type,
                        coordinate: $coordinate,
                        collapsed: $collapsed,
                        viewHeight: $viewHeight,
                        shouldShowUpgradeButton: $viewModel.shouldShowUpgradeButton,
                        shouldHideMenuBar: $viewModel.shouldHideMenuBar,
                        backAction: {
                            viewModel.router.back()
                        },
                        findAction: {
                            viewModel.router.backToRoot(animated: true)
                            viewModel.router.showTabScreen(tab: .discovery)
                        }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onAppear {
                        ignoreOffset = true
                    }
                } else {
                    ForEach(CourseTab.allCases) { tab in
                        switch tab {
                        case .course:
                            CourseOutlineView(
                                viewModel: viewModel,
                                title: title,
                                courseID: courseID,
                                isVideo: false,
                                selection: $viewModel.selection,
                                coordinate: $coordinate,
                                collapsed: $collapsed,
                                viewHeight: $viewHeight,
                                dateTabIndex: CourseTab.dates.rawValue
                            )
                            .tabItem {
                                tab.image
                                Text(tab.title)
                            }
                            .tag(tab)
                            .accentColor(Theme.Colors.accentColor)
                        case .videos:
                            CourseOutlineView(
                                viewModel: viewModel,
                                title: title,
                                courseID: courseID,
                                isVideo: true,
                                selection: $viewModel.selection,
                                coordinate: $coordinate,
                                collapsed: $collapsed,
                                viewHeight: $viewHeight,
                                dateTabIndex: CourseTab.dates.rawValue
                            )
                            .tabItem {
                                tab.image
                                Text(tab.title)
                            }
                            .tag(tab)
                            .accentColor(Theme.Colors.accentColor)
                        case .dates:
                            CourseDatesView(
                                courseID: courseID,
                                coordinate: $coordinate,
                                collapsed: $collapsed,
                                viewHeight: $viewHeight,
                                viewModel: courseDatesViewModel,
                                shouldShowUpgradeButton: $viewModel.shouldShowUpgradeButton,
                                shouldHideMenuBar: $viewModel.shouldHideMenuBar
                            )
                            .tabItem {
                                tab.image
                                Text(tab.title)
                            }
                            .tag(tab)
                            .accentColor(Theme.Colors.accentColor)
                        case .discussion:
                            DiscussionTopicsView(
                                courseID: courseID,
                                coordinate: $coordinate,
                                collapsed: $collapsed,
                                viewHeight: $viewHeight,
                                viewModel: Container.shared.resolve(DiscussionTopicsViewModel.self,
                                                                    argument: title)!,
                                router: Container.shared.resolve(DiscussionRouter.self)!,
                                shouldShowUpgradeButton: $viewModel.shouldShowUpgradeButton,
                                shouldHideMenuBar: $viewModel.shouldHideMenuBar
                            )
                            .tabItem {
                                tab.image
                                Text(tab.title)
                            }
                            .tag(tab)
                            .accentColor(Theme.Colors.accentColor)
                        case .handounds:
                            HandoutsView(
                                courseID: courseID,
                                coordinate: $coordinate,
                                collapsed: $collapsed,
                                viewHeight: $viewHeight,
                                viewModel: Container.shared.resolve(HandoutsViewModel.self, argument: courseID)!,
                                shouldShowUpgradeButton: $viewModel.shouldShowUpgradeButton,
                                shouldHideMenuBar: $viewModel.shouldHideMenuBar
                            )
                            .tabItem {
                                tab.image
                                Text(tab.title)
                            }
                            .tag(tab)
                            .accentColor(Theme.Colors.accentColor)
                        }
                    }
                }
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .introspect(.scrollView, on: .iOS(.v15, .v16, .v17), customize: { tabView in
            tabView.isScrollEnabled = false
        })
        .onFirstAppear {
            Task {
                await viewModel.tryToRefreshCookies()
            }
        }
    }
    
    private func didSelect(_ selection: Int) {
        lastCoordinate = .zero
        ignoreOffset = true
        CourseTab(rawValue: selection).flatMap {
            viewModel.trackSelectedTab(
                selection: $0,
                courseId: courseID,
                courseName: title
            )
        }
    }
    
    private func collapseHeader(_ coordinate: CGFloat) {
        guard !isHorizontal else { return collapsed = true }
        let lowerBound: CGFloat = -90
        let upperBound: CGFloat = 160
        
        switch coordinate {
        case lowerBound...upperBound:
            if shouldAnimateHeader(coordinate: coordinate) {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.6, blendDuration: 0.6)) {
                    ignoreOffset = false
                    collapsed = false
                }
            } else {
                lastCoordinate = coordinate
            }
        default:
            if shouldAnimateHeader(coordinate: coordinate) {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.6, blendDuration: 0.6)) {
                    ignoreOffset = false
                    collapsed = true
                }
            } else {
                lastCoordinate = coordinate
            }
        }
    }
    
    private func shouldAnimateHeader(coordinate: CGFloat) -> Bool {
        let ignoringOffset: CGFloat = 120
        
        guard coordinate <= ignoringOffset, lastCoordinate != 0 else {
            return false
        }
        
        if collapsed && lastCoordinate > coordinate {
            return false
        }
        
        if !collapsed && lastCoordinate < coordinate {
            return false
        }
        
        return true
    }
}

#if DEBUG
struct CourseScreensView_Previews: PreviewProvider {
    static var previews: some View {
        CourseContainerView(
            viewModel: CourseContainerViewModel(
                interactor: CourseInteractor.mock,
                authInteractor: AuthInteractor.mock,
                router: CourseRouterMock(),
                analytics: CourseAnalyticsMock(),
                config: ConfigMock(),
                connectivity: Connectivity(),
                manager: DownloadManagerMock(),
                storage: CourseStorageMock(),
                isActive: true,
                courseStart: nil,
                courseEnd: nil,
                enrollmentStart: nil,
                enrollmentEnd: nil,
                lastVisitedBlockID: nil,
                coreAnalytics: CoreAnalyticsMock(),
                serverConfig: ServerConfigProtocolMock()
            ),
            courseDatesViewModel: CourseDatesViewModel(
                interactor: CourseInteractor.mock,
                router: CourseRouterMock(),
                cssInjector: CSSInjectorMock(),
                connectivity: Connectivity(),
                config: ConfigMock(),
                courseID: "1",
                courseName: "a",
                analytics: CourseAnalyticsMock()
            ),
            courseID: "",
            title: "Title of Course",
            org: "Org",
            courseRawImage: nil,
            coursewareAccess: nil
        )
    }
}
#endif
