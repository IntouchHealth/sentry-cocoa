import XCTest

class SentryCrashIntegrationTests: XCTestCase {
    
    private static let dsnAsString = TestConstants.dsnAsString(username: "SentryCrashIntegrationTests")
    private static let dsn = TestConstants.dsn(username: "SentryCrashIntegrationTests")
    
    private class Fixture {
        
        let currentDateProvider = TestCurrentDateProvider()
        let dispatchQueueWrapper = TestSentryDispatchQueueWrapper()
        let hub: SentryHub
        let options: Options
        let sentryCrash: TestSentryCrashAdapter
        let releaseName = "1.0.0"
        let dist = "14G60"
        
        init() {
            sentryCrash = TestSentryCrashAdapter.sharedInstance()
            sentryCrash.internalActiveDurationSinceLastCrash = 5.0
            sentryCrash.internalCrashedLastLaunch = true
            
            options = Options()
            options.dsn = SentryCrashIntegrationTests.dsnAsString
            options.releaseName = TestData.appState.releaseName
            options.dist = dist
            
            let client = Client(options: options)
            hub = TestHub(client: client, andScope: nil)
        }
        
        var session: SentrySession {
            let session = SentrySession(releaseName: "1.0.0")
            session.incrementErrors()
            
            return session
        }
        
        var fileManager: SentryFileManager {
            return try! SentryFileManager(options: options, andCurrentDateProvider: TestCurrentDateProvider())
        }
        
        func getSut() -> SentryCrashIntegration {
            return SentryCrashIntegration(crashAdapter: sentryCrash, andDispatchQueueWrapper: dispatchQueueWrapper)
        }
        
        var sutWithoutCrash: SentryCrashIntegration {
            let crash = sentryCrash
            crash.internalCrashedLastLaunch = false
            return SentryCrashIntegration(crashAdapter: crash, andDispatchQueueWrapper: dispatchQueueWrapper)
        }
    }
    
    private let fixture = Fixture()
    
    override func setUp() {
        super.setUp()
        CurrentDate.setCurrentDateProvider(fixture.currentDateProvider)
        
        fixture.fileManager.deleteCurrentSession()
        fixture.fileManager.deleteCrashedSession()
        fixture.fileManager.deleteAppState()
    }
    
    override func tearDown() {
        super.tearDown()
        fixture.fileManager.deleteCurrentSession()
        fixture.fileManager.deleteCrashedSession()
        fixture.fileManager.deleteAppState()
    }
    
    // Test for GH-581
    func testReleaseNamePassedToSentryCrash() {
        // The start of the SDK installs all integrations
        SentrySDK.start(options: ["dsn": SentryCrashIntegrationTests.dsnAsString,
                                  "release": fixture.releaseName,
                                  "dist": fixture.dist]
        )
        
        // To test this properly we need SentryCrash and SentryCrashIntegration installed and registered on the current hub of the SDK.
        // Furthermore we would need to use TestSentryDispatchQueueWrapper to make make sure the sync of the scope to SentryCrash happened, which is complicated when we call
        // SentrySDK.start.
        // Setting this up needs quite some refactoring, which is complex and we accept this
        // test smell of waiting a bit for now.
        delayNonBlocking(timeout: 0.1)
        
        let instance = SentryCrash.sharedInstance()
        let userInfo = (instance?.userInfo ?? ["": ""]) as Dictionary
        assertUserInfoField(userInfo: userInfo, key: "release", expected: fixture.releaseName)
        assertUserInfoField(userInfo: userInfo, key: "dist", expected: fixture.dist)
    }
    
    func testSetUserInfo_SyncsScopeChanges_ToSentryCrash() throws {
        SentrySDK.setCurrentHub(fixture.hub)
        
        let sut = fixture.getSut()
        sut.install(with: fixture.options)
        
        let tags = ["tag1": "tag1", "tag2": "tag2"]
        
        SentrySDK.configureScope { scope in
            scope.setTags(tags)
            scope.setExtras(["extra1": "extra1", "extra2": "extra2"])
            scope.setFingerprint(["finger", "print"])
            scope.setContext(value: ["context": 1], key: "context")
            scope.setEnvironment("Production")
            scope.setLevel(SentryLevel.fatal)
            
            let crumb1 = TestData.crumb
            crumb1.message = "Crumb 1"
            scope.add(crumb1)
            
            let crumb2 = TestData.crumb
            crumb2.message = "Crumb 2"
            scope.add(crumb2)
        }
        
        SentrySDK.setUser(TestData.user)
        
        let result = getUserInfoJSON()
        let data = result.data(using: .utf8)!
        var dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        
        SentrySDK.currentHub().scope.serialize()
        
        dict.removeValue(forKey: "release")
        dict.removeValue(forKey: "dist")
        
        XCTAssertEqual(tags, dict["tags"] as? [String: String])
        
        let dictData = try JSONSerialization.data(withJSONObject: dict)
   
        let dictString = String(data: dictData, encoding: .utf8)
        
        XCTAssertNotNil(dictString)
        
        XCTAssertNotNil(dict)
    }
    
    private func getUserInfoJSON() -> String {
        var jsonPointer = UnsafeMutablePointer<CChar>?(nil)
        sentrycrashreport_getUserInfoJSON(&jsonPointer)
        let json = String(cString: jsonPointer ?? UnsafeMutablePointer<CChar>.allocate(capacity: 0))
        
        jsonPointer?.deallocate()
        
        return json
    }
    
    func testEndSessionAsCrashed_WithCurrentSession() {
        let expectedCrashedSession = givenCrashedSession()
        SentrySDK.setCurrentHub(fixture.hub)
        
        advanceTime(bySeconds: 10)
        
        let sut = fixture.getSut()
        sut.install(with: Options())
        
        assertCrashedSessionStored(expected: expectedCrashedSession)
    }
    
    #if os(iOS) || os(tvOS) || targetEnvironment(macCatalyst)
    func testEndSessionAsCrashed_WhenOOM_WithCurrentSession() {
        givenOOMAppState()
        
        let expectedCrashedSession = givenCrashedSession()
        
        SentrySDK.setCurrentHub(fixture.hub)
        advanceTime(bySeconds: 10)
        
        let sut = fixture.sutWithoutCrash
        sut.install(with: fixture.options)
        
        assertCrashedSessionStored(expected: expectedCrashedSession)
    }
    
    func testOutOfMemoryTrackingDisabled() {
        givenOOMAppState()
        
        let session = givenCurrentSession()
        
        let sut = fixture.sutWithoutCrash
        let options = fixture.options
        options.enableOutOfMemoryTracking = false
        sut.install(with: options)
        
        let fileManager = fixture.fileManager
        XCTAssertEqual(session, fileManager.readCurrentSession())
        XCTAssertNil(fileManager.readCrashedSession())
    }
    
    #endif
    
    func testEndSessionAsCrashed_NoClientSet() {
        let hub = SentryHub(client: nil, andScope: nil)
        SentrySDK.setCurrentHub(hub)
        
        let sut = fixture.getSut()
        sut.install(with: Options())
        
        let fileManager = fixture.fileManager
        XCTAssertNil(fileManager.readCurrentSession())
        XCTAssertNil(fileManager.readCrashedSession())
    }
    
    func testEndSessionAsCrashed_NoCrashLastLaunch() {
        let session = givenCurrentSession()
        
        let sentryCrash = fixture.sentryCrash
        sentryCrash.internalCrashedLastLaunch = false
        let sut = SentryCrashIntegration(crashAdapter: sentryCrash, andDispatchQueueWrapper: fixture.dispatchQueueWrapper)
        sut.install(with: Options())
        
        let fileManager = fixture.fileManager
        XCTAssertEqual(session, fileManager.readCurrentSession())
        XCTAssertNil(fileManager.readCrashedSession())
    }
    
    func testEndSessionAsCrashed_NoCurrentSession() {
        SentrySDK.setCurrentHub(fixture.hub)
        
        let sut = fixture.getSut()
        sut.install(with: Options())
        
        let fileManager = fixture.fileManager
        XCTAssertNil(fileManager.readCurrentSession())
        XCTAssertNil(fileManager.readCrashedSession())
    }
    
    func testInstall_WhenStitchAsyncCallsEnabled_CallsInstallAsyncHooks() {
        let sut = fixture.getSut()
        
        let options = Options()
        options.stitchAsyncCode = true
        sut.install(with: options)
        
        XCTAssertTrue(fixture.sentryCrash.installAsyncHooksCalled)
    }
    
    func testInstall_WhenStitchAsyncCallsDisabled_DoesNotCallInstallAsyncHooks() {
        fixture.getSut().install(with: Options())
        
        XCTAssertFalse(fixture.sentryCrash.installAsyncHooksCalled)
    }
    
    func testUninstall_CallsDeactivateAsyncHooks() {
        let sut = fixture.getSut()
        
        sut.install(with: Options())
        
        sut.uninstall()
        
        XCTAssertTrue(fixture.sentryCrash.deactivateAsyncHooksCalled)
    }
    
    func testOSCorrectlySetToScopeContext() {
        let hub = fixture.hub
        SentrySDK.setCurrentHub(hub)
        
        let sut = fixture.getSut()
        sut.install(with: Options())
        
        let context = hub.scope.serialize()["context"]as? [String: Any] ?? ["": ""]
        
        guard let os = context["os"] as? [String: Any] else {
            XCTFail("No OS found on context.")
            return
        }
        
        guard let device = context["device"] as? [String: Any] else {
            XCTFail("No device found on context.")
            return
        }
        
        #if targetEnvironment(macCatalyst) || os(macOS)
        XCTAssertEqual("macOS", device["family"] as? String)
        XCTAssertEqual("macOS", os["name"] as? String)
        
        let osVersion = ProcessInfo().operatingSystemVersion
        XCTAssertEqual("\(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)", os["version"] as? String)
        #elseif os(iOS)
        XCTAssertEqual("iOS", device["family"] as? String)
        XCTAssertEqual("iOS", os["name"] as? String)
        XCTAssertEqual(UIDevice.current.systemVersion, os["version"] as? String)
        #elseif os(tvOS)
        XCTAssertEqual("tvOS", device["family"] as? String)
        XCTAssertEqual("tvOS", os["name"] as? String)
        XCTAssertEqual(UIDevice.current.systemVersion, os["version"] as? String)
        #endif
    }
    
    private func givenCurrentSession() -> SentrySession {
        // serialize sets the timestamp
        let session = SentrySession(jsonObject: fixture.session.serialize())!
        fixture.fileManager.storeCurrentSession(session)
        return session
    }
    
    private func givenCrashedSession() -> SentrySession {
        let session = givenCurrentSession()
        session.endCrashed(withTimestamp: fixture.currentDateProvider.date().addingTimeInterval(5))
        
        return session
    }
    
    #if os(iOS) || os(tvOS) || targetEnvironment(macCatalyst)
    private func givenOOMAppState() {
        let appState = SentryAppState(releaseName: TestData.appState.releaseName, osVersion: UIDevice.current.systemVersion, isDebugging: false, systemBootTimestamp: fixture.currentDateProvider.date())
        appState.isActive = true
        fixture.fileManager.store(appState)
    }
    #endif
    
    private func assertUserInfoField(userInfo: [AnyHashable: Any], key: String, expected: String) {
        if let actual = userInfo[key] as? String {
            XCTAssertEqual(expected, actual)
        } else {
            XCTFail("\(key) not passed to SentryCrash.userInfo")
        }
    }
    
    private func assertCrashedSessionStored(expected: SentrySession) {
        let crashedSession = fixture.fileManager.readCrashedSession()
        XCTAssertEqual(SentrySessionStatus.crashed, crashedSession?.status)
        XCTAssertEqual(expected, crashedSession)
        XCTAssertNil(fixture.fileManager.readCurrentSession())
    }
    
    private func advanceTime(bySeconds: TimeInterval) {
        fixture.currentDateProvider.setDate(date: fixture.currentDateProvider.date().addingTimeInterval(bySeconds))
    }
}
