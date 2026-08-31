@ui @playlists @playback
Feature: Playlist playback
  As a listener
  I want playlists to play in their set order or shuffled
  So that I can control or vary the listening sequence

  Background:
    Given the local library contains these folders and ordered tracks:
      | folder  | order | track        |
      | Morning | 1     | First Coffee |
      | Morning | 2     | Sunrise      |
      | Evening | 1     | City Lights  |
      | Evening | 2     | Last Train   |

  Scenario: Play an individual-track playlist in order
    Given "Singles" contains these individual tracks in order:
      | track       |
      | Last Train  |
      | Sunrise     |
      | City Lights |
    When I choose "Play" on "Singles"
    Then "Last Train" starts playing
    And the playback queue is:
      | track       |
      | Last Train  |
      | Sunrise     |
      | City Lights |
    And shuffle is disabled

  Scenario: Play expands folders at their ordered position
    Given "Commute" contains these items in order:
      | kind   | title       |
      | track  | Last Train  |
      | folder | Morning     |
      | track  | City Lights |
    When I choose "Play" on "Commute"
    Then the playback queue is:
      | track        |
      | Last Train   |
      | First Coffee |
      | Sunrise      |
      | City Lights  |

  Scenario: Reordering playlist items changes ordered playback
    Given "Commute" contains the folder "Morning" before the track "Last Train"
    When I move "Last Train" before "Morning"
    And I choose "Play" on "Commute"
    Then "Last Train" starts playing
    And both "Morning" tracks follow it in folder order

  Scenario: Overlapping folder and track items do not duplicate playback
    Given "Commute" contains the folder "Morning"
    And "Commute" also contains the individual track "Sunrise"
    When I choose "Play" on "Commute"
    Then "Sunrise" appears exactly once in the playback queue
    And "First Coffee" appears exactly once in the playback queue

  Scenario: Overlapping folders do not duplicate playback
    Given two playlist folder items resolve to the track "Sunrise"
    When I choose "Play" on the playlist
    Then "Sunrise" appears exactly once in the playback queue
    And the first occurrence determines its queue position

  Scenario: Shuffle plays all resolved tracks once
    Given "Commute" contains the folders "Morning" and "Evening"
    When I choose "Shuffle" on "Commute"
    Then shuffle is enabled
    And one available playlist track starts playing
    And the playback queue contains each resolved playlist track exactly once
    And the queue contains no track outside "Commute"

  Scenario: Play switches an existing shuffled session back to set order
    Given shuffle is enabled
    And "Commute" has a set order
    When I choose "Play" on "Commute"
    Then shuffle is disabled
    And playback begins in the set playlist order

  Scenario: Shuffle switches an ordered session into shuffle mode
    Given shuffle is disabled
    When I choose "Shuffle" on a non-empty playlist
    Then shuffle is enabled
    And shuffled playlist playback begins

  Scenario: Unavailable entries are skipped during playback
    Given "Commute" contains an unavailable track before "City Lights"
    When I choose "Play" on "Commute"
    Then "City Lights" starts playing
    And the unavailable track is not in the playback queue

  Scenario: An empty playlist cannot start playback
    Given an empty playlist named "Empty" exists
    When I open "Empty"
    Then the "Play" action is disabled
    And the "Shuffle" action is disabled
    And the current playback session is unchanged

  Scenario: A playlist whose items are all unavailable cannot start playback
    Given "Unavailable" contains only unavailable items
    When I open "Unavailable"
    Then its available track count is 0
    And the "Play" action is disabled
    And the "Shuffle" action is disabled

  Scenario: Open a folder item from a playlist
    Given "Commute" contains the folder "Morning"
    When I open the "Morning" playlist item
    Then the folder collection screen is displayed
    And it offers folder-level "Play" and "Shuffle" actions
    And its existing track menus remain available
