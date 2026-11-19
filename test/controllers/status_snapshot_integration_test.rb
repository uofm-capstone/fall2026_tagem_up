require "test_helper"
require "minitest/mock"

class StatusSnapshotIntegrationTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @user = users(:one)
    @semester = semesters(:one)
    @cache = ActiveSupport::Cache::MemoryStore.new

    @coordinator = StatusSnapshotCoordinator.new(
      semester: @semester,
      user: @user
    )

    sign_in @user
  end

  test "displays initial snapshot prompt when cache is empty" do
    Rails.stub(:cache, @cache) do
      get semester_status_content_path(@semester)

      assert_response :success
      assert_select '[data-status-content-ready="1"]'
      assert_select '[data-status-refreshing="0"]'
      assert_match "No saved status snapshot", response.body
    end
  end

  test "requests background generation without executing it synchronously" do
    Rails.stub(:cache, @cache) do
      assert_enqueued_jobs 1, only: StatusSnapshotJob do
        get semester_status_content_path(@semester),
            params: { force_refresh: 1 }
      end

      assert_response :success
      assert_select '[data-status-refreshing="1"]'
      assert @coordinator.refreshing?
    end
  end

  test "displays generation failure notification" do
    Rails.stub(:cache, @cache) do
        @cache.write(
            "#{@coordinator.cache_key}:error",
            Time.current
        )

        get semester_status_content_path(@semester)

        assert_response :success
        assert_match "Status snapshot generation failed", response.body
        assert_match "Retry Snapshot Generation", response.body
    end
  end

  test "renders an existing snapshot without scheduling a job" do
        built_at = 2.minutes.ago

        payload = {
            team_project_data: {},
            team_board_health: {},
            team_sprint_metrics: {},
            team_status_overview: [],
            team_overview_by_id: {},
            github_inspector: {},
            status_metrics: {}
        }

        Rails.stub(:cache, @cache) do
            @cache.write(
            @coordinator.cache_key,
            { payload: payload, built_at: built_at }
            )

            assert_no_enqueued_jobs(only: StatusSnapshotJob) do
            get semester_status_content_path(@semester)
            end

            assert_response :success
            assert_select '[data-status-content-ready="1"]'
            assert_select '[data-status-refreshing="0"]'
            assert_select '#status-snapshot-age'

            assert_match "Status snapshot updated", response.body
        end
    end
    test "preserves existing snapshot while refresh is in progress" do
        payload = {
            team_project_data: {},
            team_board_health: {},
            team_sprint_metrics: {},
            team_status_overview: [],
            team_overview_by_id: {},
            github_inspector: {},
            status_metrics: {}
        }

        snapshot = {
            payload: payload,
            built_at: 5.minutes.ago
        }

        Rails.stub(:cache, @cache) do
            @cache.write(@coordinator.cache_key, snapshot)

            assert_enqueued_jobs 1, only: StatusSnapshotJob do
            get semester_status_content_path(@semester),
                params: { force_refresh: 1 }
            end

            assert_response :success
            assert_select '[data-status-refreshing="1"]'
            assert_select '#status-snapshot-age'
            assert_match "Previously saved metrics", response.body

            assert_equal snapshot, @coordinator.snapshot
        end
    end
    test "allows TA to browse and select semesters without management controls" do
        sign_out @user

        ta = users(:two)
        ta.update_columns(
            role: User.roles[:ta],
            admin: false,
            temp_password_changed: true
        )

        sign_in ta

        get semesters_path

        assert_response :success
        assert_select 'button', text: "Select"
        assert_select '#newSemesterModal', count: 0
        assert_select '[id^="editSemesterModal-"]', count: 0
        assert_select '[id^="deleteSemesterModal-"]', count: 0

        post select_semester_path(@semester)

        assert_redirected_to semesters_path
        assert_equal @semester.id, session[:last_viewed_semester_id]
    end
    test "allows TA to access status and request snapshot generation" do
        sign_out @user

        ta = users(:two)
        ta.update_columns(
            role: User.roles[:ta],
            admin: false,
            temp_password_changed: true
        )

        sign_in ta

        get semester_status_path(@semester)
        assert_response :success

        Rails.stub(:cache, @cache) do
            get semester_status_content_path(@semester)

            assert_response :success
            assert_match "No saved status snapshot", response.body

            assert_enqueued_jobs 1, only: StatusSnapshotJob do
            get semester_status_content_path(@semester),
                params: { force_refresh: 1 }
            end

            assert_response :success
            assert_select '[data-status-refreshing="1"]'
        end
    end
    test "prevents TA from modifying semesters" do
        sign_out @user

        ta = users(:two)
        ta.update_columns(
            role: User.roles[:ta],
            admin: false,
            temp_password_changed: true
        )

        sign_in ta

        assert_no_difference "Semester.count" do
            post semesters_path,
                params: { semester: "Fall", year: 2030 }

            assert_response :redirect
        end

        original_year = @semester.year

        patch semester_path(@semester),
                params: { semester: { year: 2030 } }

        assert_response :redirect
        assert_equal original_year, @semester.reload.year

        assert_no_difference "Semester.count" do
            delete semester_path(@semester)

            assert_response :redirect
        end
    end
    test "denies status access to students and guests" do
        sign_out @user

        user = users(:two)

        [:student, :guest].each do |role|
            user.update_columns(
            role: User.roles[role],
            admin: false,
            temp_password_changed: true
            )

            sign_in user.reload

            get semester_status_path(@semester)
            assert_redirected_to semesters_path

            get semester_status_content_path(@semester)
            assert_redirected_to semesters_path

            assert_no_enqueued_jobs(only: StatusSnapshotJob) do
            get semester_status_content_path(@semester),
                params: { force_refresh: 1 }

            assert_redirected_to semesters_path
            end

            sign_out user
        end
    end
    test "displays synchronous snapshot prompt without scheduling a job" do
        previous_value = ENV["STATUS_BACKGROUND_ENABLED"]
        ENV["STATUS_BACKGROUND_ENABLED"] = "false"

        Rails.stub(:cache, @cache) do
            assert_no_enqueued_jobs(only: StatusSnapshotJob) do
                get semester_status_content_path(@semester)
            end

            assert_response :success
            assert_match "No saved status snapshot", response.body
        end
    ensure
        ENV["STATUS_BACKGROUND_ENABLED"] = previous_value
    end
    test "generates and retrieves synchronous snapshot when background generation is disabled" do
        previous_value = ENV["STATUS_BACKGROUND_ENABLED"]
        ENV["STATUS_BACKGROUND_ENABLED"] = "false"

        Rails.stub(:cache, @cache) do
            assert_no_enqueued_jobs(only: StatusSnapshotJob) do
            get semester_status_content_path(@semester),
                params: { force_refresh: 1 }
            end

            assert_response :success
            assert_select '#status-snapshot-age'
            assert_select '[data-status-refreshing="0"]'

            get semester_status_content_path(@semester)

            assert_response :success
            assert_select '#status-snapshot-age'
            assert_match "Status snapshot updated", response.body

            assert_no_enqueued_jobs(only: StatusSnapshotJob)
        end
    ensure
        ENV["STATUS_BACKGROUND_ENABLED"] = previous_value
    end
end