require "test_helper"
require "minitest/mock"

class SemestersControllerTest < ActiveSupport::TestCase
  test "github sprint metrics include the entire final day" do
    sprint = Sprint.new(
      name: "Sprint 3",
      start_date: Time.zone.parse("2026-10-15 00:00:00"),
      end_date: Time.zone.parse("2026-11-03 00:00:00")
    )

    start_time = sprint.start_date.beginning_of_day
    end_time = sprint.end_date.end_of_day

    assert_equal Time.zone.parse("2026-10-15 00:00:00"), start_time
    assert_equal sprint.end_date.end_of_day, end_time

    assert start_time <= Time.zone.parse("2026-10-15 00:00:00")
    assert end_time >= Time.zone.parse("2026-11-03 23:59:59")
    assert end_time < Time.zone.parse("2026-11-04 00:00:00")
  end

  test "github metrics use full sprint date boundaries" do
    sprint = Sprint.new(
        start_date: Time.zone.parse("2026-10-15"),
        end_date: Time.zone.parse("2026-11-03")
    )

    expected_start = sprint.start_date.beginning_of_day
    expected_end = sprint.end_date.end_of_day

    service = Minitest::Mock.new

    service.expect(:available?, true)

    service.expect(
        :commit_metrics_by_user,
        {},
        ["owner/repo", expected_start, expected_end],
        cache_version: nil,
        force_refresh: false
    )

    service.expect(
        :last_commit_at_by_user,
        {},
        ["owner/repo", expected_start, expected_end],
        cache_version: nil,
        force_refresh: false
    )

    service.expect(
        :last_commit_at_by_user,
        {},
        [
        "owner/repo",
        expected_end.to_date - 180.days,
        expected_end.to_date
        ],
        cache_version: ":fallback_last_commit",
        force_refresh: false
    )

    service.expect(
        :pr_metrics_by_user,
        {},
        ["owner/repo", expected_start, expected_end],
        cache_version: nil,
        force_refresh: false
    )

    service.expect(
        :review_metrics_by_user,
        {},
        ["owner/repo", expected_start, expected_end],
        cache_version: nil,
        force_refresh: false
    )

    controller = SemestersController.new

    result = controller.send(
        :build_github_sprint_metrics,
        team_service: service,
        repo: "owner/repo",
        sprint: sprint,
        students: []
    )

    assert result[:data_available]
    service.verify
    end
    test "github metrics correctly aggregate student contributions" do
    sprint = Sprint.new(
        start_date: Time.zone.parse("2026-10-15"),
        end_date: Time.zone.parse("2026-11-03")
    )

    students = [students(:one), students(:two)]

    service = Minitest::Mock.new
    service.expect(:available?, true)

    service.expect(
        :commit_metrics_by_user,
        {
        "student_one" => GithubService::CBPResult.new(5, 100, 20, 120),
        "student_two" => GithubService::CBPResult.new(3, 60, 20, 80)
        },
        [String, Time, Time],
        cache_version: nil,
        force_refresh: false
    )

    service.expect(
        :last_commit_at_by_user,
        {},
        [String, Time, Time],
        cache_version: nil,
        force_refresh: false
    )

    service.expect(
        :last_commit_at_by_user,
        {},
        [String, Date, Date],
        cache_version: ":fallback_last_commit",
        force_refresh: false
    )

    service.expect(
        :pr_metrics_by_user,
        {
        "student_one" => GithubService::PRResult.new(2, 1, 1, 12.0),
        "student_two" => GithubService::PRResult.new(1, 1, 0, 8.0)
        },
        [String, Time, Time],
        cache_version: nil,
        force_refresh: false
    )

    service.expect(
        :review_metrics_by_user,
        {
        "student_one" => GithubService::ReviewResult.new(4, 3, 1),
        "student_two" => GithubService::ReviewResult.new(2, 1, 1)
        },
        [String, Time, Time],
        cache_version: nil,
        force_refresh: false
    )

    result = SemestersController.new.send(
        :build_github_sprint_metrics,
        team_service: service,
        repo: "owner/repo",
        sprint: sprint,
        students: students
    )

    assert result[:data_available], "GitHub metrics should be available"

    # Commit totals
    assert_equal 8, result[:cbp][:total_commits]
    assert_equal 200, result[:cbp][:total_lines_changed]
    assert_equal 2, result[:cbp][:active_contributors]

    # Pull request totals
    assert_equal 3, result[:pr][:opened_count]
    assert_equal 2, result[:pr][:merged_count]
    assert_equal 1, result[:pr][:open_count]

    # Review totals
    assert_equal 6, result[:review][:review_count]
    assert_equal 4, result[:review][:approvals]
    assert_equal 2, result[:review][:changes_requested]

    # Individual contributions remain separate
    assert_equal 5, result[:per_student]["student_one"][:cbp][:commit_count]
    assert_equal 3, result[:per_student]["student_two"][:cbp][:commit_count]

    service.verify
    end

    test "different sprints use different reporting windows" do
        sprint_two = Sprint.new(
            start_date: Time.zone.parse("2026-09-22"),
            end_date: Time.zone.parse("2026-10-09")
        )

        sprint_three = Sprint.new(
            start_date: Time.zone.parse("2026-10-15"),
            end_date: Time.zone.parse("2026-11-03")
        )

        [sprint_two, sprint_three].each do |sprint|
            expected_start = sprint.start_date.beginning_of_day
            expected_end = sprint.end_date.end_of_day

            service = Minitest::Mock.new
            service.expect(:available?, true)

            service.expect(
            :commit_metrics_by_user,
            {},
            ["owner/repo", expected_start, expected_end],
            cache_version: nil,
            force_refresh: false
            )

            service.expect(
            :last_commit_at_by_user,
            {},
            ["owner/repo", expected_start, expected_end],
            cache_version: nil,
            force_refresh: false
            )

            service.expect(
            :last_commit_at_by_user,
            {},
            [
                "owner/repo",
                expected_end.to_date - 180.days,
                expected_end.to_date
            ],
            cache_version: ":fallback_last_commit",
            force_refresh: false
            )

            service.expect(
            :pr_metrics_by_user,
            {},
            ["owner/repo", expected_start, expected_end],
            cache_version: nil,
            force_refresh: false
            )

            service.expect(
            :review_metrics_by_user,
            {},
            ["owner/repo", expected_start, expected_end],
            cache_version: nil,
            force_refresh: false
            )

            result = SemestersController.new.send(
            :build_github_sprint_metrics,
            team_service: service,
            repo: "owner/repo",
            sprint: sprint,
            students: []
            )

            assert result[:data_available]
            service.verify
        end

        assert_not_equal(
            sprint_two.start_date.beginning_of_day,
            sprint_three.start_date.beginning_of_day
        )

        assert_not_equal(
            sprint_two.end_date.end_of_day,
            sprint_three.end_date.end_of_day
        )
        end
end