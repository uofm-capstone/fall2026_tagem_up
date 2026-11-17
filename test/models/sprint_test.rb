require "test_helper"

class SprintTest < ActiveSupport::TestCase
  setup do
    @sprint = Sprint.new(
      name: "Test Sprint",
      semester: Semester.new,
      start_date: Date.new(2026, 11, 1),
      end_date: Date.new(2026, 11, 15)
    )
  end

  test "accepts a valid date range" do
    assert @sprint.valid?
  end

  test "accepts the same start and end date" do
    @sprint.end_date = @sprint.start_date

    assert @sprint.valid?
  end

  test "rejects an end date before the start date" do
    @sprint.end_date = @sprint.start_date - 1.day

    assert_not @sprint.valid?
    assert_includes @sprint.errors[:end_date],
                    "must be on or after the start date"
  end

  test "requires a start date" do
    @sprint.start_date = nil

    assert_not @sprint.valid?
    assert @sprint.errors[:start_date].present?
  end

  test "requires an end date" do
    @sprint.end_date = nil

    assert_not @sprint.valid?
    assert @sprint.errors[:end_date].present?
  end
end