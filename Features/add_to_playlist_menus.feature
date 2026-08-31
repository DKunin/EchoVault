@ui @playlists @menus
Feature: Add to Playlist from music action menus
  As a listener
  I want Add to Playlist beside every Play Next action
  So that I can save music without navigating away from its current context

  Background:
    Given a playlist named "Commute" exists

  Scenario Outline: Every local track menu with Play Next offers Add to Playlist
    Given the local track "City Lights" is visible in <surface>
    When I open the <menu> for "City Lights"
    Then I see "Play Next"
    And I see "Add to End of Queue"
    And I see "Add to Playlist"

    Examples:
      | surface                              | menu         |
      | an expanded Library folder           | More actions |
      | an expanded Library folder           | context menu |
      | the Library Tracks view              | More actions |
      | the Library Tracks view              | context menu |
      | the Library Favourites view          | More actions |
      | the Library Favourites view          | context menu |
      | a Library folder detail              | More actions |
      | a Library folder detail              | context menu |
      | an album detail opened from Now Playing | More actions |
      | an album detail opened from Now Playing | context menu |
      | an artist detail opened from Now Playing | More actions |
      | an artist detail opened from Now Playing | context menu |
      | an online WebDAV directory           | More actions |
      | an online WebDAV directory           | context menu |
      | the WebDAV offline fallback section  | More actions |
      | the WebDAV offline fallback section  | context menu |

  Scenario: Add an individual local track to an existing playlist
    Given the local track "City Lights" is not in "Commute"
    When I choose "Add to Playlist" for "City Lights"
    Then the playlist picker is displayed
    And it lists "Commute"
    When I choose "Commute"
    Then the picker closes
    And "City Lights" is an individual item in "Commute"
    And the change is saved immediately

  Scenario: Add a local folder from its queue menu
    Given the local folder "Morning" is not in "Commute"
    When I open the action menu for "Morning"
    Then I see "Play Folder Next"
    And I see "Add Folder to End of Queue"
    And I see "Add Folder to Playlist"
    When I choose "Add Folder to Playlist"
    And I choose "Commute"
    Then "Morning" is one folder item in "Commute"
    And all available "Morning" tracks resolve for playlist playback
    And the change is saved immediately

  Scenario Outline: Playlist item menus also offer Add to Playlist
    Given "Source" contains the <kind> "<title>"
    And "Target" does not contain the <kind> "<title>"
    When I open the action menu for "<title>" in "Source"
    Then I see "<play_next>"
    And I see "Add to Playlist"
    When I choose "Add to Playlist"
    And I choose "Target"
    Then "Target" contains the <kind> "<title>"

    Examples:
      | kind   | title       | play_next       |
      | track  | City Lights | Play Next       |
      | folder | Morning     | Play Folder Next |

  Scenario: Create a playlist while adding a track
    Given no playlists exist
    And the local track "City Lights" is visible
    When I choose "Add to Playlist" for "City Lights"
    Then the playlist picker offers "New Playlist"
    When I create a playlist named "Night Drive"
    Then "Night Drive" is created
    And "City Lights" is added to "Night Drive"
    And both changes are saved immediately

  Scenario: Create a playlist while adding a folder
    Given no playlists exist
    And the local folder "Morning" is visible
    When I choose "Add Folder to Playlist" for "Morning"
    And I create a playlist named "Wake Up"
    Then "Wake Up" is created
    And "Morning" is one folder item in "Wake Up"
    And both changes are saved immediately

  Scenario: Cancel the playlist picker without changing data
    Given "City Lights" is not in "Commute"
    When I choose "Add to Playlist" for "City Lights"
    And I cancel the playlist picker
    Then "City Lights" is not in "Commute"

  Scenario: Selecting a playlist that already contains the item is safe
    Given "Commute" already contains the track "City Lights"
    When I choose "Add to Playlist" for "City Lights"
    And I choose "Commute"
    Then I see "Already in playlist"
    And "Commute" contains one "City Lights" item

  @webdav
  Scenario: A cached WebDAV track can be added without downloading again
    Given "Remote Song" is already available offline from WebDAV
    And "Remote Song" is not in "Commute"
    When I choose "Add to Playlist" for "Remote Song" in WebDAV
    And I choose "Commute"
    Then no additional download is started
    And "Remote Song" is an individual item in "Commute"
    And the change is saved immediately

  @webdav
  Scenario: An uncached WebDAV track downloads before the playlist picker opens
    Given "Remote Song" is visible in WebDAV but is not available offline
    When I choose "Add to Playlist" for "Remote Song"
    Then EchoVault downloads and caches "Remote Song"
    And the playlist picker opens after the local track is available
    When I choose "Commute"
    Then "Remote Song" is an individual item in "Commute"
    And it is available for offline playlist playback

  @webdav @failure
  Scenario: A failed WebDAV download does not modify a playlist
    Given "Remote Song" is not cached
    And downloading "Remote Song" will fail
    When I choose "Add to Playlist" for "Remote Song"
    Then I see "Could not add to playlist"
    And the error reason is displayed
    And the playlist picker does not open
    And "Commute" is unchanged

  Scenario: Closing a newly created playlist sheet without creating does not add music
    Given no playlists exist
    When I choose "Add to Playlist" for "City Lights"
    And I open "New Playlist"
    And I cancel playlist creation
    Then no playlist is created
    And "City Lights" is not added anywhere
