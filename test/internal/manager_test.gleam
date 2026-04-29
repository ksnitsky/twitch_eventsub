import gleeunit/should
import internal/manager

pub fn calculate_backoff_initial_test() {
  manager.calculate_backoff(0)
  |> should.equal(1000)
}

pub fn calculate_backoff_second_attempt_test() {
  manager.calculate_backoff(1)
  |> should.equal(2000)
}

pub fn calculate_backoff_third_attempt_test() {
  manager.calculate_backoff(2)
  |> should.equal(4000)
}

pub fn calculate_backoff_max_test() {
  manager.calculate_backoff(10)
  |> should.equal(60_000)
}
