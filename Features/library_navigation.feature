@ui @library @playlists
Feature: Library and playlist navigation
  As a listener
  I want folders to be the primary way into my library and playlists to have their own tab
  So that I can reach the music organization I use most often

  Background:
    Given EchoVault has finished loading the local music library

  Scenario: Folders opens by default
    When I launch EchoVault
    Then the "Library" tab is selected
    And the Library view mode is "Folders"
    And the folder list is visible

  Scenario: Albums is no longer a Library view mode
    When I open the Library view-mode selector
    Then the available modes are:
      | mode       |
      | Folders    |
      | Tracks     |
      | Favourites |
    And an "Albums" mode is not available

  Scenario: Existing Library modes remain usable
    Given the library contains tracks and favourite tracks
    When I select each available Library view mode
    Then "Folders" shows the library folders
    And "Tracks" shows all local tracks
    And "Favourites" shows only favourite tracks

  Scenario: Album navigation from Now Playing remains available
    Given a track with album metadata is playing
    When I open Now Playing
    And I open the current album
    Then the album collection screen is displayed
    And its available tracks can still be played

  Scenario: Playlists is a primary application tab
    When I launch EchoVault
    Then the tab bar contains the following tabs in order:
      | tab       |
      | Library   |
      | Playlists |
      | WebDAV    |
      | Settings  |
    When I select the "Playlists" tab
    Then the Playlists screen is displayed in its own navigation stack

  Scenario: Empty playlists screen offers playlist creation
    Given no playlists exist
    When I open the "Playlists" tab
    Then I see "No playlists yet"
    And I see a "New Playlist" action
