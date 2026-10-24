Feature: Bounded ClickHouse HTTP client
  Scenario: Confirmed insert and typed parameterized select
    Given a disposable authenticated ClickHouse server
    When a compiled Roc application inserts JSONEachRow with async insertion enabled
    And selects using a parameter containing quotes, Unicode and URL delimiters
    Then the acknowledged rows are stored and decoded without changing their values

  Scenario: Failed queries never return successful partial rows
    Given the same server and client
    When credentials are wrong, SQL is invalid or query execution fails
    Then the client returns an explicit ClickHouse error

  Scenario: Transport and result limits
    When the server disconnects, exceeds the response budget or misses the deadline
    Then the client returns an error without retrying the operation
