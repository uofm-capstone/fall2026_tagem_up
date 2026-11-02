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

    
    test "github service is unavailable without a token" do
        service = GithubService.new(token: "")

        assert_not service.available?
        assert_equal [], service.commits_in_range(
            "example/repository",
            Time.zone.parse("2026-10-01"),
            Time.zone.parse("2026-10-14")
        )
    end

    
    test "unauthorized GitHub requests raise an authentication error" do
        service = GithubService.new(token: "invalid-test-token")

        start_date = Time.zone.parse("2026-10-01")
        end_date = Time.zone.parse("2026-10-14")

        client = Object.new

        def client.commits(*)
            raise Octokit::Unauthorized
        end

        service.instance_variable_set(:@client, client)

        assert_raises(Octokit::Unauthorized) do
            service.commits_in_range(
            "example/unauthorized-test",
            start_date,
            end_date,
            force_refresh: true
            )
        end
    end


    test "commit metrics propagate GitHub API rate limit errors" do
        service = GithubService.new(token: "test-token")

        client = Object.new

        def client.commits(*)
            raise Octokit::TooManyRequests
        end

        service.instance_variable_set(:@client, client)

        assert_raises(Octokit::TooManyRequests) do
            service.commit_metrics_by_user(
            "example/rate-limit-test",
            Time.zone.parse("2026-10-01"),
            Time.zone.parse("2026-10-14"),
            force_refresh: true
            )
        end
    end


    test "retrieves commits across multiple GitHub API pages" do
        service = GithubService.new(token: "test-token")

        start_date = Time.zone.parse("2026-10-01")
        end_date = Time.zone.parse("2026-10-14")
        repo = "example/pagination-test"

        first_page = (1..100).map { |i| "commit-#{i}" }
        second_page = (101..125).map { |i| "commit-#{i}" }

        client = Minitest::Mock.new

        client.expect(
            :commits,
            first_page,
            [repo],
            per_page: 100,
            page: 1,
            since: start_date,
            until: end_date
        )

        client.expect(
            :commits,
            second_page,
            [repo],
            per_page: 100,
            page: 2,
            since: start_date,
            until: end_date
        )

        service.instance_variable_set(:@client, client)

        result = service.commits_in_range(
            repo,
            start_date,
            end_date,
            force_refresh: true
        )

        assert_equal 125, result.length
        assert_equal first_page + second_page, result

        client.verify
    end
end