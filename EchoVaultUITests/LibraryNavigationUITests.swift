import XCTest

final class LibraryNavigationUITests: XCTestCase {
    @MainActor
    func testPrimaryNavigationAndImportMenu() throws {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.descendants(matching: .any)["library.view"].waitForExistence(timeout: 5))
        let libraryMode = app.segmentedControls["library.mode"]
        XCTAssertTrue(libraryMode.waitForExistence(timeout: 2))
        XCTAssertTrue(libraryMode.buttons["Folders"].isSelected)
        XCTAssertFalse(libraryMode.buttons["Albums"].exists)

        app.tabBars.buttons["Playlists"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["playlists.view"].waitForExistence(timeout: 2))

        let playlistName = "UI Playlist \(UUID().uuidString.prefix(8))"
        app.buttons["playlist.create"].tap()
        let nameField = app.textFields["playlist.create.name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 2))
        nameField.tap()
        nameField.typeText(playlistName)
        app.buttons["playlist.create.confirm"].tap()
        XCTAssertTrue(app.staticTexts[playlistName].waitForExistence(timeout: 2))

        app.tabBars.buttons["WebDAV"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["webdav.view"].waitForExistence(timeout: 2))

        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["settings.view"].waitForExistence(timeout: 2))

        app.tabBars.buttons["Library"].tap()
        app.buttons["library.import"].tap()
        XCTAssertTrue(app.buttons["library.import.files"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["library.import.folder"].exists)
    }
}
