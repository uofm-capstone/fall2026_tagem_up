require "test_helper"
require "minitest/mock"

class GithubServiceTest < ActiveSupport::TestCase
  test "reuses cached commit lists for the same repository and date range" do
    service = GithubService.new(token: "test-token")

    start_date = Time.zone.parse("2026-10-01 00:00:00")
    end_date = Time.zone.parse("2026-10-14 23:59:59")

    client = Minitest::Mock.new

    client.expect(
        :commits,
        [],
        ["example/repository"],
        per_page: 100,
        page: 1,
        since: start_date,
        until: end_date
    )

    service.instance_variable_set(:@client, client)

    first_result = service.commits_in_range(
      "example/repository", start_date, end_date
    )

    second_result = service.commits_in_range(
      "example/repository", start_date, end_date
    )

    assert_equal [], first_result
    assert_equal first_result, second_result

    client.verify
  end

  test "force refresh bypasses the cached commit list" do
        service = GithubService.new(token: "test-token")

        start_date = Time.zone.parse("2026-10-01 00:00:00")
        end_date = Time.zone.parse("2026-10-14 23:59:59")

        client = Minitest::Mock.new

        2.times do
            client.expect(
            :commits,
            [],
            ["example/refresh-test-repository"],
            per_page: 100,
            page: 1,
            since: start_date,
            until: end_date
            )
        end

        service.instance_variable_set(:@client, client)

        service.commits_in_range(
            "example/refresh-test-repository",
            start_date,
            end_date
        )

        service.commits_in_range(
            "example/refresh-test-repository",
            start_date,
            end_date,
            force_refresh: true
        )

        client.verify
    end

    test "commit metrics and last commit timestamps share the cached commit list" do
        service = GithubService.new(token: "test-token")

        start_date = Time.zone.parse("2026-09-01 00:00:00")
        end_date = Time.zone.parse("2026-09-14 23:59:59")
        repo = "example/shared-cache-test"

        client = Minitest::Mock.new

        client.expect(
            :commits,
            [],
            [repo],
            per_page: 100,
            page: 1,
            since: start_date,
            until: end_date
        )

        service.instance_variable_set(:@client, client)

        service.commit_metrics_by_user(
            repo,
            start_date,
            end_date,
            force_refresh: true
        )

        service.last_commit_at_by_user(
            repo,
            start_date,
            end_date,
            force_refresh: true
        )

        client.verify
     end
end