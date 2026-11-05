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

  Scenario: Typed query and scalar fidelity
    When a query returns UInt64 bounds, Decimal, DateTime64, UUID and nullable columns
    Then annotated Roc records decode without manual field extraction or precision loss
    And missing columns, incompatible values and numeric overflow fail explicitly

  Scenario: Lazy row streaming
    Given a response split inside a UTF-8 code point and across row boundaries
    When the consumer requests rows one at a time
    Then complete records arrive before the response ends without collecting its body
    And stopping consumption stops reading
    And a late exception or truncated row yields one terminal error after earlier rows
    And an oversized row fails within the configured row budget

  Scenario: Bounded confirmed insert batches
    Given an effectful stream of records
    When inserting with byte and row limits
    Then each bounded batch is acknowledged before pulling the next batch
    And byte boundaries retain at most one encoded lookahead row
    And a failed batch reports confirmed progress and stops without retrying

  Scenario: Compression and server cancellation
    When sending gzip-compressed JSONEachRow and receiving a gzip response
    Then records survive and decompression obeys the response budget
    When cancelling a running query by its bound query ID
    Then ClickHouse stops the query and reports cancellation status
