@ui @playlists @persistence
Feature: Playlist lifecycle and content management
  As a listener
  I want to create persistent playlists containing folders and individual tracks
  So that I can arrange reusable listening sessions

  Background:
    Given the local library contains these folders and tracks:
      | folder       | track            | artist       |
      | Morning      | Sunrise          | North Shore  |
      | Morning      | First Coffee     | North Shore  |
      | Evening      | City Lights      | Signal Coast |
      | Evening      | Last Train       | Signal Coast |
      | Spoken Notes | Chapter One      | Narrator     |
    And I am on the Playlists screen

  Scenario: Create an empty playlist
    Given no playlist named "Commute" exists
    When I create a playlist named "Commute"
    Then "Commute" appears on the Playlists screen
    And "Commute" contains 0 items
    And the playlist is saved immediately

  Scenario: Playlist names are trimmed before saving
    When I create a playlist named "  Focus  "
    Then a playlist named "Focus" exists
    And no playlist named "  Focus  " exists

  Scenario: Empty playlist names cannot be submitted
    When I open the New Playlist sheet
    And I enter only whitespace as the playlist name
    Then the "Create" action is disabled
    And no playlist is created

  Scenario: Playlist names are unique without regard to case or diacritics
    Given a playlist named "Focus" exists
    When I try to create a playlist named "fócus"
    Then I see "A playlist with this name already exists."
    And only one matching playlist exists

  Scenario: Open a playlist as a folder-like collection
    Given a playlist named "Commute" exists
    When I open the "Commute" playlist
    Then I see a playlist header
    And I see the available track count
    And I see "Play" and "Shuffle" actions
    And I see "Edit" and "Add Music" actions
    And I see a "Contents" section when the playlist has items

  Scenario: Add an individual track from inside a playlist
    Given an empty playlist named "Commute" exists
    When I open "Commute"
    And I open "Add Music"
    And I add the track "City Lights"
    Then "City Lights" is an individual item in "Commute"
    And "City Lights" is marked as added in the music picker
    And the change is saved immediately

  Scenario: Add a folder from inside a playlist
    Given an empty playlist named "Commute" exists
    When I open "Commute"
    And I open "Add Music"
    And I add the folder "Morning"
    Then "Morning" is one folder item in "Commute"
    And the playlist reports 2 available tracks
    And "Morning" is marked as added in the music picker
    And the change is saved immediately

  Scenario: Search for content while adding music
    Given an empty playlist named "Commute" exists
    When I open the Add Music picker for "Commute"
    And I search for "City"
    Then I see the track "City Lights"
    And I do not see the track "Sunrise"
    And folders or tracks with matching metadata remain available

  Scenario: Adding the same individual item twice is idempotent
    Given "Commute" contains the track "City Lights"
    When I try to add the track "City Lights" again from Add Music
    Then the track is shown as already added
    And "Commute" still contains one "City Lights" item

  Scenario: Adding the same folder item twice is idempotent
    Given "Commute" contains the folder "Morning"
    When I try to add the folder "Morning" again from Add Music
    Then the folder is shown as already added
    And "Commute" still contains one "Morning" folder item

  Scenario: Add multiple different items without closing the picker
    Given an empty playlist named "Commute" exists
    When I open the Add Music picker for "Commute"
    And I add the folder "Morning"
    And I add the track "Last Train"
    And I finish adding music
    Then "Commute" contains these items in order:
      | kind   | title      |
      | folder | Morning    |
      | track  | Last Train |

  Scenario: Remove an individual track using its menu
    Given "Commute" contains the track "City Lights"
    When I choose "Remove from Playlist" for "City Lights"
    Then "City Lights" is no longer an item in "Commute"
    And the audio file "City Lights" remains in the local library
    And the change is saved immediately

  Scenario: Remove a folder using a swipe action
    Given "Commute" contains the folder "Morning"
    When I swipe to remove the "Morning" playlist item
    Then "Morning" is no longer an item in "Commute"
    And the tracks in "Morning" remain in the local library
    And the change is saved immediately

  Scenario: Remove playlist items in Edit mode
    Given "Commute" contains the folder "Morning" and the track "Last Train"
    When I enter playlist Edit mode
    And I delete the "Last Train" item
    Then "Commute" contains only the "Morning" item
    And the change is saved immediately

  Scenario: Reorder mixed playlist items
    Given "Commute" contains these items in order:
      | kind   | title       |
      | folder | Morning     |
      | track  | Last Train  |
      | folder | Spoken Notes |
    When I enter playlist Edit mode
    And I move "Spoken Notes" before "Morning"
    Then "Commute" contains these items in order:
      | kind   | title        |
      | folder | Spoken Notes |
      | folder | Morning      |
      | track  | Last Train   |
    And the new order is saved immediately

  Scenario: A folder item reflects the current available folder contents
    Given "Commute" contains the folder "Morning"
    And "Morning" currently resolves to "First Coffee" and "Sunrise"
    When a new local track "Daybreak" becomes part of "Morning"
    And the library refreshes
    Then "Commute" includes "Daybreak" when resolving the "Morning" item
    And the stored playlist still contains one "Morning" folder item

  Scenario: An unavailable item remains removable without blocking the playlist
    Given "Commute" references a track that is no longer available locally
    When I open "Commute"
    Then the missing item is labelled "Unavailable track"
    And I can remove the unavailable item
    And available playlist items remain usable

  Scenario: Delete a playlist without deleting music
    Given a playlist named "Commute" contains folders and tracks
    When I request deletion of "Commute"
    Then I am warned that music files will stay on the device
    When I confirm "Delete Playlist"
    Then "Commute" no longer exists
    And every referenced folder and track remains in the local library
    And the deletion is saved immediately

  Scenario: Cancel playlist deletion
    Given a playlist named "Commute" exists
    When I request deletion of "Commute"
    And I cancel the confirmation
    Then "Commute" still exists

  Scenario: Playlists survive an application relaunch
    Given "Commute" contains the folder "Morning" and the track "Last Train"
    And "Last Train" is ordered before "Morning"
    When EchoVault terminates and relaunches
    Then the playlist "Commute" still exists
    And its items remain in this order:
      | kind   | title      |
      | track  | Last Train |
      | folder | Morning    |

  Scenario: Unsupported saved playlist data fails safely
    Given the saved playlist snapshot has an unsupported version
    When EchoVault loads the playlist store
    Then no corrupt playlist is displayed
    And I see that saved playlists use an unsupported format
    And the rest of EchoVault remains usable
