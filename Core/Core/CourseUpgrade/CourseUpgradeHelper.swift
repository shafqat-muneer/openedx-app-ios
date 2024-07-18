//
//  CourseUpgradeHelper.swift
//  Core
//
//  Created by Saeed Bashir on 4/24/24.
//

import Foundation
import StoreKit
import SwiftUI
import MessageUI
import Alamofire

private let InProgressIAPKey = "InProgressIAPKey"

public struct CourseUpgradeHelperModel {
    let courseID: String
    let blockID: String?
    let screen: CourseUpgradeScreen
}

public enum UpgradeCompletionState {
    case initial
    case payment
    case fulfillment(showLoader: Bool)
    case success(_ courseID: String, _ componentID: String?)
    case error(UpgradeError)
}

public enum UpgradeAlertType: String {
    case priceFetch = "price_fetch"
    case basket
    case checkout
    case payment
    case execute
    case restore
    case unfulfilled
    case unknown
}

// These error actions are used to send in analytics
public enum UpgradeErrorAction: String {
    case refreshToRetry = "refresh"
    case reloadPrice = "reload_price"
    case emailSupport = "get_help"
    case close
}

// These alert actions are used to send in analytics
public enum UpgradeAlertAction: String {
    case close
    case continueWithoutUpdate = "continue_without_update"
    case getHelp = "get_help"
    case refresh
}

public enum Pacing: String {
    case selfPace = "self"
    case instructor
}

public protocol CourseUpgradeHelperDelegate: AnyObject {
    func hideAlertAction()
}

public class CourseUpgradeHelper: CourseUpgradeHelperProtocol {
    
    weak private(set) var delegate: CourseUpgradeHelperDelegate?
    private(set) var completion: (() -> Void)?
    private(set) var helperModel: CourseUpgradeHelperModel?
    private(set) var config: ConfigProtocol
    private(set) var analytics: CoreAnalytics
    
    private var pacing: String?
    private var courseID: String?
    private var blockID: String?
    private var screen: CourseUpgradeScreen = .unknown
    private var localizedPrice: NSDecimalNumber?
    private var localizedCurrencyCode: String?
    private var lmsPrice: Double?
    weak private(set) var upgradeHadler: CourseUpgradeHandler?
    private let router: BaseRouter
    
    public init(
        config: ConfigProtocol,
        analytics: CoreAnalytics,
        router: BaseRouter
    ) {
        self.config = config
        self.analytics = analytics
        self.router = router
    }
    
    public func setData(
        courseID: String,
        pacing: String,
        blockID: String? = nil,
        localizedPrice: NSDecimalNumber?,
        localizedCurrencyCode: String?,
        lmsPrice: Double?,
        screen: CourseUpgradeScreen
    ) {
        self.courseID = courseID
        self.pacing = pacing
        self.blockID = blockID
        self.localizedPrice = localizedPrice
        self.screen = screen
        self.localizedCurrencyCode = localizedCurrencyCode
        self.lmsPrice = lmsPrice
    }
    
    public func handleCourseUpgrade(
        upgradeHadler: CourseUpgradeHandler,
        state: UpgradeCompletionState,
        delegate: CourseUpgradeHelperDelegate? = nil
    ) {
        self.delegate = delegate
        self.upgradeHadler = upgradeHadler
        
        updateInProgressIAP()
        
        switch state {
        case .fulfillment(let show):
            if show {
                showLoader()
            }
        case .success(let courseID, let blockID):
            helperModel = CourseUpgradeHelperModel(courseID: courseID, blockID: blockID, screen: screen)
            if upgradeHadler.upgradeMode == .userInitiated {
                removeLoader(success: true, shouldRemoveView: true)
                postSuccessNotification()
            } else {
                showSilentRefreshAlert()
            }
        case .error(let error):
            if case .paymentError = error {
                if error.isCancelled {
                    analytics.trackCourseUpgradePaymentError(
                        .courseUpgradePaymentCancelError,
                        biValue: .courseUpgradePaymentCancelError,
                        courseID: courseID ?? "",
                        blockID: blockID,
                        pacing: pacing ?? "",
                        localizedPrice: localizedPrice,
                        localizedCurrencyCode: localizedCurrencyCode,
                        lmsPrice: lmsPrice,
                        screen: screen,
                        error: error.formattedError
                    )
                } else {
                    analytics.trackCourseUpgradePaymentError(
                        .courseUpgradePaymentError,
                        biValue: .courseUpgradePaymentError,
                        courseID: courseID ?? "",
                        blockID: blockID,
                        pacing: pacing ?? "",
                        localizedPrice: localizedPrice,
                        localizedCurrencyCode: localizedCurrencyCode,
                        lmsPrice: lmsPrice,
                        screen: screen,
                        error: error.formattedError
                    )
                }
            } else {
                analytics.trackCourseUpgradeError(
                    courseID: courseID ?? "",
                    blockID: blockID,
                    pacing: pacing ?? "",
                    localizedPrice: localizedPrice,
                    localizedCurrencyCode: localizedCurrencyCode,
                    lmsPrice: lmsPrice,
                    screen: screen,
                    error: error.formattedError,
                    flowType: upgradeHadler.upgradeMode
                )
            }
            
            var shouldRemove: Bool = false
            if case .verifyReceiptError = error {
                shouldRemove = false
            } else {
                shouldRemove = true
            }
            
            removeLoader(success: false, shouldRemoveView: shouldRemove)
        
        default:
            break
        }
    }
    
    private func updateInProgressIAP() {
        guard let state = upgradeHadler?.state,
              let courseID = courseID,
              let upgradeMode = upgradeHadler?.upgradeMode,
              let sku = upgradeHadler?.courseSku,
              sku.isEmpty == false
        else { return }
        
        switch state {
        case .basket:
            saveInProgressIAP(courseID: courseID, sku: sku, lmsPrice: lmsPrice ?? .zero)
        case .complete:
            removeInProgressIAP()
        case .error(let upgradeError):
            if case .verifyReceiptError(let error) = upgradeError, error.errorCode == 409 {
                removeInProgressIAP()
            }
            
            if upgradeError != .verifyReceiptError(upgradeError), upgradeMode == .userInitiated {
                removeInProgressIAP()
            }
        default:
            break
        }
    }
    
    private func postSuccessNotification(showLoader: Bool = false) {
        NotificationCenter.default.post(name: .courseUpgradeCompletionNotification, object: showLoader)
    }
    
    private func showDashboardScreen() {
        router.backToRoot(animated: true)
    }
    
    public func resetUpgradeModel() {
        helperModel = nil
        delegate = nil
    }
    
    private func reset() {
        pacing = nil
        courseID = nil
        blockID = nil
        localizedPrice = nil
        screen = .unknown
        resetUpgradeModel()
    }
}

extension CourseUpgradeHelper {
    func trackAndResetOnSuccess() {
        analytics.trackCourseUpgradeSuccess(
            courseID: courseID ?? "",
            blockID: blockID,
            pacing: pacing ?? "",
            localizedPrice: localizedPrice,
            localizedCurrencyCode: localizedCurrencyCode,
            lmsPrice: lmsPrice,
            screen: screen,
            flowType: upgradeHadler?.upgradeMode ?? .userInitiated
        )
        reset()
    }
    
    func showError() {
        // not showing any error if payment is canceled by user
        if case .error(let error) = upgradeHadler?.state {
            if error.isCancelled { return }
            
            var actions: [UIAlertAction] = []
            
            if case .verifyReceiptError(let nestedError) = error, nestedError.errorCode != 409 {
                actions.append(
                    UIAlertAction(
                        title: CoreLocalization.CourseUpgrade.FailureAlert.refreshToRetry,
                        style: .default,
                        handler: { [weak self] _ in
                            guard let self = self else { return }
                            self.trackUpgradeErrorAction(
                                errorAction: .refreshToRetry,
                                error: error,
                                alertType: .execute
                            )
                            Task {
                                await self.upgradeHadler?.reverifyPayment()
                            }
                        }
                    )
                )
            }
            
            if case .complete = upgradeHadler?.state, completion != nil {
                actions.append(
                    UIAlertAction(
                        title: CoreLocalization.CourseUpgrade.FailureAlert.refreshToRetry,
                        style: .default,
                        handler: { [weak self] _ in
                            self?.trackUpgradeErrorAction(
                                errorAction: .refreshToRetry,
                                error: error,
                                alertType: self?.alertType ?? .unknown
                            )
                            self?.showLoader()
                            self?.completion?()
                            self?.completion = nil
                        }
                    )
                )
            }
            
            actions.append(
                UIAlertAction(
                    title: CoreLocalization.CourseUpgrade.FailureAlert.getHelp,
                    style: .default,
                    handler: { [weak self] _ in
                        guard let self = self else { return }
                        self.trackUpgradeErrorAction(
                            errorAction: .emailSupport,
                            error: error,
                            alertType: self.alertType
                        )
                        self.hideAlertAction()
                        Task { @MainActor in
                            await self.router.hideUpgradeLoaderView(animated: true)
                        }
                        self.launchEmailComposer(errorMessage: "Error: \(error.formattedError)")
                    }
                )
            )

            actions.append(
                UIAlertAction(
                    title: CoreLocalization.close,
                    style: .default,
                    handler: { [weak self] _ in
                        guard let self = self else { return }
                        Task { @MainActor in
                            await self.router.hideUpgradeLoaderView(animated: true)
                            self.trackUpgradeErrorAction(errorAction: .close, error: error, alertType: self.alertType)
                            self.hideAlertAction()
                        }
                    }
                )
            )

            router.presentNativeAlert(
                title: CoreLocalization.CourseUpgrade.FailureAlert.alertTitle,
                message: error.localizedDescription,
                actions: actions
            )
        }
    }
    
    private var alertType: UpgradeAlertType {
        switch upgradeHadler?.state {
        case .basket:
            return .basket
        case .checkout:
            return .checkout
        case .payment:
            return .payment
        case .verify, .complete:
            return .execute
        default:
            return .unknown
        }
    }
    
    private func hideAlertAction() {
        delegate?.hideAlertAction()
        reset()
    }
}

extension CourseUpgradeHelper {
    public func showLoader(animated: Bool = false, completion: (() -> Void)? = nil) {
        Task {@MainActor [weak self] in
            guard let self = self else { return }
            await self.router.hideUpgradeInfo(animated: false)
            await self.router.showUpgradeLoaderView(animated: animated)
            completion?()
        }
    }
    
    public func removeLoader(
        success: Bool? = false,
        shouldRemoveView: Bool? = false,
        completion: (() -> Void)? = nil
    ) {
        self.completion = completion
        if success == true {
            helperModel = nil
        }
        
        if shouldRemoveView == true {
            Task {@MainActor in
                await router.hideUpgradeLoaderView(animated: true)
                helperModel = nil
                
                if success == true {
                    trackAndResetOnSuccess()
                } else {
                    showError()
                }
            }
        } else if success == false {
            showError()
        }
    }
}

extension CourseUpgradeHelper {
    private func showSilentRefreshAlert() {
        var actions: [UIAlertAction] = []

        actions.append(
            UIAlertAction(
                title: CoreLocalization.CourseUpgrade.SuccessAlert.silentAlertRefresh,
                style: .default
            ) { [weak self] _ in
                self?.showDashboardScreen()
                self?.postSuccessNotification(showLoader: true)
            }
        )
        
        actions.append(
            UIAlertAction(
                title: CoreLocalization.CourseUpgrade.SuccessAlert.silentAlertContinue,
                style: .default
            ) { [weak self] _ in
                self?.reset()
            }
        )

        router.presentNativeAlert(
            title: CoreLocalization.CourseUpgrade.SuccessAlert.silentAlertTitle,
            message: CoreLocalization.CourseUpgrade.SuccessAlert.silentAlertMessage,
            actions: actions
        )
    }
    
    public func showRestorePurchasesAlert() {
        var actions: [UIAlertAction] = []
        
        actions.append(
            UIAlertAction(
                title: CoreLocalization.CourseUpgrade.FailureAlert.getHelp,
                style: .default
            ) { [weak self] _ in
                self?.launchEmailComposer(errorMessage: "Error: restore_purchases")
                self?.trackUpgradeErrorAction(errorAction: .emailSupport, alertType: .restore)
            }
        )
        
        actions.append(
            UIAlertAction(
                title: CoreLocalization.close,
                style: .default
            ) { [weak self] _ in
                self?.trackUpgradeErrorAction(errorAction: .close, alertType: .restore)
            }
        )
        
        router.presentNativeAlert(
            title: CoreLocalization.CourseUpgrade.Restore.alertTitle,
            message: CoreLocalization.CourseUpgrade.Restore.alertMessage,
            actions: actions
        )
    }
}

extension CourseUpgradeHelper {
    private func trackUpgradeErrorAction(
        errorAction: UpgradeErrorAction,
        error: UpgradeError? = nil,
        alertType: UpgradeAlertType
    ) {
        analytics.trackCourseUpgradeErrorAction(
            courseID: courseID ?? "",
            blockID: blockID,
            pacing: pacing ?? "",
            localizedPrice: localizedPrice,
            localizedCurrencyCode: localizedCurrencyCode,
            lmsPrice: lmsPrice,
            screen: screen,
            alertType: alertType,
            errorAction: errorAction.rawValue,
            error: error?.formattedError ?? "",
            flowType: upgradeHadler?.upgradeMode ?? .userInitiated
        )
    }
}

extension CourseUpgradeHelper {
    func launchEmailComposer(errorMessage: String) {
        guard let emailURL = EmailTemplates.contactSupport(
            email: config.feedbackEmail,
            emailSubject: CoreLocalization.CourseUpgrade.supportEmailSubject,
            errorMessage: errorMessage
        ), UIApplication.shared.canOpenURL(emailURL) else {
            
            if let topController = UIApplication.topViewController() {
                UIAlertController().showAlert(
                    withTitle: CoreLocalization.CourseUpgrade.emailNotSetupTitle,
                    message: CoreLocalization.Error.cannotSendEmail,
                    cancelButtonTitle: CoreLocalization.ok,
                    onViewController: topController) { _, _, _ in }
            }
            
            return
        }
        
        UIApplication.shared.open(emailURL)
    }
}

// Save course upgrade data in user deualts for unfulfilled cases if any
// Enrollments API is paginated so it's not sure the course will be available in first response

extension CourseUpgradeHelper {
    private func saveInProgressIAP(courseID: String, sku: String, lmsPrice: Double) {
        let IAP = InProgressIAP(courseID: courseID, sku: sku, pacing: pacing ?? "", lmsPrice: lmsPrice)
        
        if let data = try? NSKeyedArchiver.archivedData(withRootObject: IAP, requiringSecureCoding: true) {
            UserDefaults.standard.set(data, forKey: InProgressIAPKey)
            UserDefaults.standard.synchronize()
        }
    }
    
    public class func getInProgressIAP() -> InProgressIAP? {
        guard let data = UserDefaults.standard.object(forKey: InProgressIAPKey) as? Data else {
            return nil
        }
        
        let IAP = try? NSKeyedUnarchiver.unarchivedObject(ofClass: InProgressIAP.self, from: data)
        
        return IAP
    }
    
    private func removeInProgressIAP() {
        UserDefaults.standard.removeObject(forKey: InProgressIAPKey)
        UserDefaults.standard.synchronize()
    }
}

public class InProgressIAP: NSObject, NSCoding, NSSecureCoding {
    
    public var courseID: String = ""
    public var sku: String = ""
    public var pacing: String = ""
    public var lmsPrice: Double = 0.0
    
    init(courseID: String, sku: String, pacing: String, lmsPrice: Double) {
        self.courseID = courseID
        self.sku = sku
        self.pacing = pacing
        self.lmsPrice = lmsPrice
    }
    
    public func encode(with coder: NSCoder) {
        coder.encode(courseID, forKey: "courseID")
        coder.encode(sku, forKey: "sku")
        coder.encode(pacing, forKey: "pacing")
        coder.encode(lmsPrice, forKey: "lmsPrice")
    }
    
    public required init?(coder: NSCoder) {
        courseID = coder.decodeObject(forKey: "courseID") as? String ?? ""
        sku = coder.decodeObject(forKey: "sku") as? String ?? ""
        pacing = coder.decodeObject(forKey: "pacing") as? String ?? ""
        lmsPrice = coder.decodeObject(forKey: "lmsPrice") as? Double ?? .zero
    }
    
    public static var supportsSecureCoding: Bool {
        return true
    }
}