require "test_helper"
require "minitest/mock"

class StatusSnapshotJobTest < ActiveJob::TestCase
  CACHE_KEY = "status_snapshot:test"

  setup do
    @cache = ActiveSupport::Cache::MemoryStore.new
    @semester = Semester.new
    @user = User.new

    @payload = {
      team_status_overview: [
        { team_id: 1 },
        { team_id: 2 }
      ]
    }
  end

  test "generates and caches snapshot successfully" do
    service = Minitest::Mock.new
    service.expect(:call, @payload)

    @cache.write("#{CACHE_KEY}:refreshing", Time.current)

    with_mocked_service(service) do
      StatusSnapshotJob.perform_now(1, 1, CACHE_KEY)
    end

    snapshot = @cache.read(CACHE_KEY)

    assert_equal @payload, snapshot[:payload]
    assert_not_nil snapshot[:built_at]
    assert_nil @cache.read("#{CACHE_KEY}:refreshing")
    assert_nil @cache.read("#{CACHE_KEY}:error")

    service.verify
  end

  test "preserves previous snapshot when generation fails" do
    previous_snapshot = {
      payload: @payload,
      built_at: 1.hour.ago
    }

    @cache.write(CACHE_KEY, previous_snapshot)
    @cache.write("#{CACHE_KEY}:refreshing", Time.current)

    service = Object.new

    def service.call
      raise StandardError, "Simulated generation failure"
    end

    with_mocked_service(service) do
      assert_raises(StandardError) do
        StatusSnapshotJob.perform_now(1, 1, CACHE_KEY)
      end
    end

    assert_equal previous_snapshot, @cache.read(CACHE_KEY)
    assert_nil @cache.read("#{CACHE_KEY}:refreshing")
    assert_not_nil @cache.read("#{CACHE_KEY}:error")
  end

  private

  def with_mocked_service(service)
    Rails.stub(:cache, @cache) do
      Semester.stub(:find, @semester) do
        User.stub(:find, @user) do
          StatusSnapshotService.stub(:new, ->(**_kwargs) { service }) do
            yield
          end
        end
      end
    end
  end
end