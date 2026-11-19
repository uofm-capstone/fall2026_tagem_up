require "test_helper"
require "minitest/mock"

class StatusSnapshotCoordinatorTest < ActiveJob::TestCase
  setup do
    @cache = ActiveSupport::Cache::MemoryStore.new
    @sprints = []
    def @sprints.order(*args)
        self
    end
    @semester = Struct.new(:id, :sprints).new(1, @sprints)
    @user = User.new(id: 1)

    @coordinator = StatusSnapshotCoordinator.new(
      semester: @semester,
      user: @user
    )
  end

  test "retrieves existing snapshot" do
    snapshot = {
      payload: { team_status_overview: [] },
      built_at: Time.current
    }

    Rails.stub(:cache, @cache) do
      @cache.write(@coordinator.cache_key, snapshot)

      assert_equal snapshot, @coordinator.snapshot
    end
  end

  test "requests background refresh" do
    Rails.stub(:cache, @cache) do
      assert_not @coordinator.refreshing?

      assert_enqueued_jobs 1, only: StatusSnapshotJob do
        assert @coordinator.request_refresh
      end

      assert @coordinator.refreshing?
    end
  end

  test "prevents duplicate refresh requests" do
    Rails.stub(:cache, @cache) do
      assert_enqueued_jobs 1, only: StatusSnapshotJob do
        assert @coordinator.request_refresh
        assert_not @coordinator.request_refresh
      end
    end
  end

  test "clears refresh marker if job enqueue fails" do
    Rails.stub(:cache, @cache) do
      StatusSnapshotJob.stub(:perform_later, false) do
        assert_not @coordinator.request_refresh
        assert_not @coordinator.refreshing?
      end
    end
  end

  test "cache key remains stable when sprints are unchanged" do
        @sprints << build_test_sprint

        assert_equal @coordinator.cache_key, @coordinator.cache_key
    end

  test "cache key changes when sprint dates change" do
        sprint = build_test_sprint
        @sprints << sprint

        original_key = @coordinator.cache_key

        sprint.end_date += 1.day
        updated_key = @coordinator.cache_key

        assert_not_equal original_key, updated_key

        sprint.start_date += 1.day

        assert_not_equal updated_key, @coordinator.cache_key
    end

  test "cache key changes when a sprint is added" do
        original_key = @coordinator.cache_key

        @sprints << build_test_sprint

        assert_not_equal original_key, @coordinator.cache_key
    end

    test "cache key changes when a sprint is removed" do
        @sprints << build_test_sprint
        original_key = @coordinator.cache_key

        @sprints.clear

        assert_not_equal original_key, @coordinator.cache_key
    end

    test "cache key changes when a sprint is renamed" do
        sprint = build_test_sprint
        @sprints << sprint

        original_key = @coordinator.cache_key
        sprint.name = "Updated Sprint"

        assert_not_equal original_key, @coordinator.cache_key
    end

    private

    def build_test_sprint
        Sprint.new(
            id: 1,
            name: "Sprint 1",
            start_date: Date.new(2026, 10, 1),
            end_date: Date.new(2026, 10, 15)
        )
    end
end