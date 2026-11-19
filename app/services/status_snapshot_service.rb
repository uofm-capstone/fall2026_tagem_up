require "digest"
require "timeout"

class StatusSnapshotService
  GITHUB_SCORE_WEIGHTS = {
    kanban: 0.35,
    cbp: 0.30,
    pr: 0.20,
    review: 0.15
  }.freeze

  def initialize(semester:, user:, force_refresh: false)
    @semester = semester
    @user = user
    @force_github_refresh = force_refresh
  end

  def call
    build_status_payload!

    {
      team_project_data: @team_project_data,
      team_board_health: @team_board_health,
      team_sprint_metrics: @team_sprint_metrics,
      team_status_overview: @team_status_overview,
      team_overview_by_id: @team_overview_by_id,
      github_inspector: @github_inspector,
      status_metrics: @status_metrics
    }
  end

  def build_status_payload!
    @teams = @semester.teams.includes(:students)
    @sprint_list = @semester.sprints.pluck(:name)
    @sprints = @semester.sprints.order(:start_date)

    # Calculate metrics for display.
    @service = GithubService.new(user: @user)

    @team_project_data = {}
    @team_board_health = {}
    @team_sprint_metrics = {}
    @team_status_overview = []
    @github_inspector = {}
    @status_metrics = {}

    mutex = Mutex.new
    work_queue = Queue.new
    @teams.each { |team| work_queue << team }

    parallelism = [ENV.fetch("STATUS_PARALLELISM", 2).to_i, 1].max
    worker_count = [parallelism, @teams.size].min

    workers = worker_count.times.map do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          loop do
            team = work_queue.pop(true) rescue nil
            break unless team

            team_payload = build_team_status_payload(team)

            mutex.synchronize do
              @team_project_data[team.id] = team_payload[:project_cards]
              @team_board_health[team.id] = team_payload[:board_health]
              @team_sprint_metrics[team.id] = team_payload[:team_sprint_metrics]
              @status_metrics[team.id] = team_payload[:status_metrics]
              @team_status_overview << team_payload[:team_status_overview]
              @github_inspector[team.id] = team_payload[:github_inspector]
            end
          end
        end
      end
    end

    workers.each(&:join)

    @team_overview_by_id = @team_status_overview.index_by { |summary| summary[:team_id] }
  end

  def build_team_status_payload(team)
    team_service = GithubService.new(team: team, user: @user)
    team_cache_version = status_cache_version_for(team: team)
    board_health = safe_board_health(
      team_service: team_service,
      team: team,
      cache_version: team_cache_version,
      force_refresh: @force_github_refresh
    )
    project_cards = board_health.cards
    repo = team_service.parse_repo_url(team.repo_url)
    sprint_cards_by_name = {}
    github_metrics_by_sprint = {}
    team_sprint_metrics = {}
    status_metrics = {}
    inspector_sprints = {}

    @sprints.each do |sprint|
      sprint_cards = cards_for_sprint(project_cards, sprint)
      sprint_cards_by_name[sprint.name] = sprint_cards

      github_metrics = safe_github_sprint_metrics(
        team_service: team_service,
        repo: repo,
        sprint: sprint,
        students: team.students,
        team: team,
        cache_version: status_cache_version_for(team: team, sprint: sprint),
        force_refresh: @force_github_refresh
      )
      github_metrics_by_sprint[sprint.name] = github_metrics

      team_metric = build_team_sprint_metrics(
        sprint_cards: sprint_cards,
        board_health: board_health,
        sprint: sprint,
        students: team.students,
        github_metrics: github_metrics
      )
      team_sprint_metrics[sprint.name] = team_metric

      inspector_sprints[sprint.name] = {
        start_date: sprint.start_date,
        end_date: sprint.end_date,
        progress_deadline: sprint.progress_deadline,
        total_cards: team_metric[:total_cards],
        total_estimate: team_metric[:estimated_hours],
        total_spent: team_metric[:time_spent_hours],
        cards_missing_spent: team_metric[:cards_missing_time_spent],
        github_repo: repo,
        github_scores: team_metric[:github],
        card_time_samples: sprint_cards.map { |card| card_time_sample(card) }
      }
    end

    team.students.each do |student|
      status_metrics[student.id] = {}

      @sprints.each do |sprint|
        sprint_github_metrics = github_metrics_by_sprint[sprint.name] || {}
        status_metrics[student.id][sprint.name] = build_live_status_metrics(
          sprint_cards: sprint_cards_by_name[sprint.name],
          board_health: board_health,
          student: student,
          sprint: sprint,
          github_student_metrics: sprint_github_metrics.dig(:per_student, student.github_username),
          team_missing_data_flags: sprint_github_metrics[:missing_data_flags],
          team_github_available: sprint_github_metrics[:data_available]
        )
      end
    end

    team_status_overview = {
      team_id: team.id,
      team_name: team.name,
      students_count: team.students.count,
      any_at_risk: team_sprint_metrics.values.any? { |metric| metric[:at_risk] },
      any_missing_sprint_done: team_sprint_metrics.values.any? { |metric| metric[:missing_sprint_done] },
      at_risk_reason_preview: team_sprint_metrics.values.flat_map { |metric| metric[:at_risk_reasons] }.uniq.first(2),
      sprint_metrics: team_sprint_metrics
    }

    github_inspector = {
      project_url: team.project_board_url,
      status_options: board_health.status_options,
      card_counts: @service.get_card_count_per_column(project_cards),
      sprint_payloads: inspector_sprints
    }

    {
      project_cards: project_cards,
      board_health: board_health,
      team_sprint_metrics: team_sprint_metrics,
      status_metrics: status_metrics,
      team_status_overview: team_status_overview,
      github_inspector: github_inspector
    }
  end

  private

  def safe_board_health(team_service:, team:, cache_version: nil, force_refresh: false)
    Timeout.timeout(5) do
      team_service.board_health(
        team.project_board_url,
        cache_version: cache_version,
        force_refresh: force_refresh
      )
    end
  rescue Timeout::Error
    Rails.logger.warn("Board health query timed out for team #{team.id}")
    GithubService::BoardHealth.new([], [], false, [])
  rescue StandardError => e
    Rails.logger.warn("Board health query failed for team #{team.id}: #{e.class} - #{e.message}")
    GithubService::BoardHealth.new([], [], false, [])
  end

  # Allow additional time for GitHub API requests to retrieve sprint metrics.
  # The previous 4-second limit caused premature timeouts and incomplete results on the Team Status Page
  def safe_github_sprint_metrics(team_service:, repo:, sprint:, students:, team:, cache_version: nil, force_refresh: false)
    Timeout.timeout(30) do
      build_github_sprint_metrics(
        team_service: team_service,
        repo: repo,
        sprint: sprint,
        students: students,
        cache_version: cache_version,
        force_refresh: force_refresh
      )
    end
  rescue Timeout::Error
    Rails.logger.warn("GitHub sprint metrics timed out for team #{team.id}, sprint #{sprint.name}")
    build_last_commit_only(
      team_service: team_service,
      repo: repo,
      sprint: sprint,
      students: students,
      cache_version: cache_version,
      force_refresh: force_refresh,
      missing_data_flags: ["github_query_timeout"]
    )
  rescue StandardError => e
    Rails.logger.warn("GitHub sprint metrics failed for team #{team.id}, sprint #{sprint.name}: #{e.class} - #{e.message}")
    build_last_commit_only(
      team_service: team_service,
      repo: repo,
      sprint: sprint,
      students: students,
      cache_version: cache_version,
      force_refresh: force_refresh,
      missing_data_flags: ["github_query_failed"]
    )
  end

  def build_live_status_metrics(
    sprint_cards:,
    board_health:,
    student:,
    sprint:,
    github_student_metrics: nil,
    team_missing_data_flags: nil,
    team_github_available: nil
  )
    columns = @service.get_card_count_per_column(sprint_cards)
    sprint_done_count = sprint_cards.count { |card| done_in_sprint_status?(card.status, sprint.name) }
    done_in_any_sprint_count = sprint_cards.count { |card| done_in_any_sprint_status?(card.status) }
    current_board_done_count = count_by_status_group(columns) { |status| done_status?(status) }
    archived_count = count_by_status_group(columns) { |status| archived_status?(status) }
    active_now_count = count_by_status_group(columns) { |status| active_status?(status) }
    total_count = columns.values.sum

    per_student_column_counts = Hash.new(0)
    assigned_card_count = 0
    estimated_hours = 0
    time_spent_hours = 0

    sprint_cards.each do |card|
      next unless assignee_matches_student?(card, student)

      assigned_card_count += 1
      status = card.status || "Unspecified"
      per_student_column_counts[status] += 1
      estimated_hours += estimate_value(card)
      time_spent_hours += spent_value(card)
    end

    done_status_total = count_by_status_group(per_student_column_counts) { |status| done_status?(status) || archived_status?(status) } +
                        per_student_column_counts.select { |status_name, _count| done_in_any_sprint_status?(status_name) }.values.sum

    student_done_scope_cards = sprint_cards.select do |card|
      next false unless assignee_matches_student?(card, student)

      status = card.status.to_s
      done_in_any_sprint_status?(status) || done_status?(status) || archived_status?(status)
    end
    student_done_scope_count = student_done_scope_cards.size
    student_done_with_estimate_pct = percentage(
      student_done_scope_cards.count { |card| estimate_value(card).positive? },
      student_done_scope_count
    )
    student_done_with_time_taken_pct = percentage(
      student_done_scope_cards.count { |card| spent_value(card).positive? },
      student_done_scope_count
    )
    # KU focuses on documentation hygiene for completed student work.
    student_kanban_score = (
      (assigned_card_count.positive? ? 20.0 : 0.0) +
      (student_done_with_estimate_pct * 0.40) +
      (student_done_with_time_taken_pct * 0.40)
    ).round(1)
    student_kanban_band = assigned_card_count.zero? ? "No Data" : ku_band_for(student_kanban_score)

    student_pp_completion_pct = percentage(done_status_total, assigned_card_count).round(1)
    student_pp_band = assigned_card_count.zero? ? "No Data" : pp_band_for(student_pp_completion_pct)

    if github_student_metrics.blank?
      student_username_missing = student.github_username.to_s.strip.blank?
      inferred_flags = if student_username_missing
        ["no_github_username"]
      else
        Array(team_missing_data_flags).presence || ["github_student_data_unavailable"]
      end

      github_student_metrics = empty_student_github_metrics(
        missing_data_flags: inferred_flags,
        data_available: student_username_missing ? false : team_github_available
      )
    end
    cbp_data = github_student_metrics[:cbp] || {}
    pr_data = github_student_metrics[:pr] || {}
    review_data = github_student_metrics[:review] || {}
    last_commit_at = github_student_metrics[:last_commit_at]
    missing_data_flags = Array(github_student_metrics[:missing_data_flags])

    cbp_score = score_cbp(
      commit_count: cbp_data[:commit_count].to_i,
      lines_changed: cbp_data[:lines_changed].to_i
    )
    pr_score = score_pr(
      opened_count: pr_data[:opened_count].to_i,
      merged_count: pr_data[:merged_count].to_i,
      open_count: pr_data[:open_count].to_i,
      avg_merge_hours: pr_data[:avg_merge_hours].to_f
    )
    review_score = score_review(
      review_count: review_data[:review_count].to_i,
      approvals: review_data[:approvals].to_i,
      changes_requested: review_data[:changes_requested].to_i
    )
    has_non_kanban_github_data = (
      cbp_data[:commit_count].to_i.positive? ||
      pr_data[:opened_count].to_i.positive? ||
      review_data[:review_count].to_i.positive?
    )

    github_score = (
      (student_kanban_score * GITHUB_SCORE_WEIGHTS[:kanban]) +
      (cbp_score * GITHUB_SCORE_WEIGHTS[:cbp]) +
      (pr_score * GITHUB_SCORE_WEIGHTS[:pr]) +
      (review_score * GITHUB_SCORE_WEIGHTS[:review])
    ).round(1)
    github_band = if !github_student_metrics[:data_available] ||
                    (assigned_card_count.zero? && !has_non_kanban_github_data)
      "No Data"
    else
      github_band_for(github_score)
    end

    {
      fsd: {
        backlog: count_by_status_group(per_student_column_counts) { |status| backlog_status?(status) },
        todo: count_by_status_group(per_student_column_counts) { |status| todo_status?(status) },
        in_progress: count_by_status_group(per_student_column_counts) { |status| in_progress_status?(status) },
        done: done_status_total
      },
      fa: {
        assigned_cards: assigned_card_count
      },
      te: {
        estimated_hours: estimated_hours.round(1)
      },
      ts: {
        time_spent_hours: time_spent_hours.round(1)
      },
      ku: {
        score: student_kanban_score,
        band: student_kanban_band
      },
      pp: {
        current_board_done_cards: current_board_done_count,
        sprint_done_cards: sprint_done_count,
        done_in_any_sprint_cards: done_in_any_sprint_count,
        archived_cards: archived_count,
        active_now_cards: active_now_count,
        total_cards: total_count,
        completion_pct: student_pp_completion_pct,
        band: student_pp_band
      },
      cbp: cbp_data,
      pr: pr_data,
      review: review_data,
      last_commit_at: last_commit_at,
      last_commit: {
        at: last_commit_at,
        data_available: github_student_metrics[:data_available],
        missing_data_flags: missing_data_flags
      },
      github: {
        score: github_score,
        band: github_band,
        cbp_score: cbp_score,
        pr_score: pr_score,
        review_score: review_score,
        kanban_score: student_kanban_score,
        last_commit_at: last_commit_at,
        data_available: github_student_metrics[:data_available],
        missing_data_flags: missing_data_flags
      }
    }
  end

  def build_team_sprint_metrics(sprint_cards:, board_health:, sprint:, students:, github_metrics: nil)
    columns = @service.get_card_count_per_column(sprint_cards)
    sprint_done_count = sprint_cards.count { |card| done_in_sprint_status?(card.status, sprint.name) }
    done_in_any_sprint_count = sprint_cards.count { |card| done_in_any_sprint_status?(card.status) }
    current_board_done_count = count_by_status_group(columns) { |status| done_status?(status) }
    archived_count = count_by_status_group(columns) { |status| archived_status?(status) }
    active_now_count = count_by_status_group(columns) { |status| active_status?(status) }
    total_count = columns.values.sum

    estimated_hours = sprint_cards.sum { |card| estimate_value(card) }
    time_spent_hours = sprint_cards.sum { |card| spent_value(card) }
    cards_missing_time_spent = sprint_cards.count do |card|
      status = card.status.to_s

      completed = done_in_any_sprint_status?(status) ||
                  done_status?(status) ||
                  archived_status?(status)

      completed && spent_value(card).zero?
    end
    in_current_sprint = sprint_in_progress?(sprint)

    done_status_total = count_by_status_group(columns) { |status| done_status?(status) || archived_status?(status) } +
                        columns.select { |status_name, _count| done_in_any_sprint_status?(status_name) }.values.sum

    done_scope_cards = sprint_cards.select do |card|
      status = card.status.to_s
      done_in_any_sprint_status?(status) || done_status?(status) || archived_status?(status)
    end

    done_scope_count = done_scope_cards.size
    done_with_estimate_count = done_scope_cards.count { |card| estimate_value(card).positive? }
    done_with_time_taken_count = done_scope_cards.count { |card| spent_value(card).positive? }
    done_with_estimate_pct = percentage(done_with_estimate_count, done_scope_count)
    done_with_time_taken_pct = percentage(done_with_time_taken_count, done_scope_count)

    ku_score = (
      (done_scope_count.positive? ? 20.0 : 0.0) +
      (done_with_estimate_pct * 0.40) +
      (done_with_time_taken_pct * 0.40)
    ).round(1)
    ku_band = total_count.zero? ? "No Data" : ku_band_for(ku_score)

    github_metrics ||= empty_team_github_metrics
    cbp_score = score_cbp(
      commit_count: github_metrics.dig(:cbp, :total_commits).to_i,
      lines_changed: github_metrics.dig(:cbp, :total_lines_changed).to_i
    )
    pr_score = score_pr(
      opened_count: github_metrics.dig(:pr, :opened_count).to_i,
      merged_count: github_metrics.dig(:pr, :merged_count).to_i,
      open_count: github_metrics.dig(:pr, :open_count).to_i,
      avg_merge_hours: github_metrics.dig(:pr, :avg_merge_hours).to_f
    )
    review_score = score_review(
      review_count: github_metrics.dig(:review, :review_count).to_i,
      approvals: github_metrics.dig(:review, :approvals).to_i,
      changes_requested: github_metrics.dig(:review, :changes_requested).to_i
    )
    github_composite_score = (
      (ku_score * GITHUB_SCORE_WEIGHTS[:kanban]) +
      (cbp_score * GITHUB_SCORE_WEIGHTS[:cbp]) +
      (pr_score * GITHUB_SCORE_WEIGHTS[:pr]) +
      (review_score * GITHUB_SCORE_WEIGHTS[:review])
    ).round(1)
    github_band = github_metrics[:data_available] ? github_band_for(github_composite_score) : "No Data"

    pp_completion_pct = percentage(done_status_total, total_count).round(1)
    pp_band = total_count.zero? ? "No Data" : pp_band_for(pp_completion_pct)

    risk_reasons = []
    risk_reasons << "No completed cards in #{sprint.name}" if !in_current_sprint && sprint.end_date.present? && Date.current > sprint.end_date.to_date && done_status_total.zero?
    if !in_current_sprint && cards_missing_time_spent.positive?
      risk_reasons << "#{cards_missing_time_spent} done cards missing Time Spent"
    end

    {
      sprint_name: sprint.name,
      archived_column_exists: board_health.archived_column_exists,
      backlog_cards: count_by_status_group(columns) { |status| backlog_status?(status) },
      todo_cards: count_by_status_group(columns) { |status| todo_status?(status) },
      in_progress_cards: count_by_status_group(columns) { |status| in_progress_status?(status) },
      done_cards: done_status_total,
      current_board_done_cards: current_board_done_count,
      sprint_done_cards: sprint_done_count,
      done_in_any_sprint_cards: done_in_any_sprint_count,
      archived_cards: archived_count,
      active_now_cards: active_now_count,
      estimated_hours: estimated_hours.round(1),
      time_spent_hours: time_spent_hours.round(1),
      cards_missing_time_spent: cards_missing_time_spent,
      total_cards: total_count,
      ku_score: ku_score,
      ku_band: ku_band,
      ku_done_with_estimate_pct: done_with_estimate_pct.round(1),
      ku_done_with_time_taken_pct: done_with_time_taken_pct.round(1),
      pp_completion_pct: pp_completion_pct,
      pp_band: pp_band,
      github: {
        score: github_composite_score,
        band: github_band,
        cbp_score: cbp_score,
        pr_score: pr_score,
        review_score: review_score,
        kanban_score: ku_score,
        cbp: github_metrics[:cbp],
        pr: github_metrics[:pr],
        review: github_metrics[:review],
        data_available: github_metrics[:data_available],
        missing_data_flags: github_metrics[:missing_data_flags]
      },
      missing_sprint_done: done_status_total.zero?,
      at_risk: risk_reasons.any?,
      at_risk_reasons: risk_reasons
    }
  end

  def build_github_sprint_metrics(team_service:, repo:, sprint:, students:, cache_version: nil, force_refresh: false)
    return empty_team_github_metrics(missing_data_flags: ["repo_missing"]) if repo.blank?
    return empty_team_github_metrics(repo: repo, missing_data_flags: ["token_unavailable"]) unless team_service.available?

    start_date = (sprint.start_date || Date.current.beginning_of_month).beginning_of_day
    end_date = (sprint.end_date || Date.current.end_of_month).end_of_day
    fallback_end_date = end_date.respond_to?(:to_date) ? end_date.to_date : Date.current
    fallback_start_date = fallback_end_date - 180.days

    cbp_by_user = team_service.commit_metrics_by_user(
      repo,
      start_date,
      end_date,
      cache_version: cache_version,
      force_refresh: force_refresh
    )
    last_commit_at_by_user = team_service.last_commit_at_by_user(
      repo,
      start_date,
      end_date,
      cache_version: cache_version,
      force_refresh: force_refresh
    )
    fallback_last_commit_at_by_user = team_service.last_commit_at_by_user(
      repo,
      fallback_start_date,
      fallback_end_date,
      cache_version: "#{cache_version}:fallback_last_commit",
      force_refresh: force_refresh
    )
    pr_by_user = team_service.pr_metrics_by_user(
      repo,
      start_date,
      end_date,
      cache_version: cache_version,
      force_refresh: force_refresh
    )
    review_by_user = team_service.review_metrics_by_user(
      repo,
      start_date,
      end_date,
      cache_version: cache_version,
      force_refresh: force_refresh
    )

    per_student = {}
    students.each do |student|
      username = student.github_username.to_s
      next if username.blank?

      cbp = lookup_user_metric(cbp_by_user, username) || GithubService::CBPResult.new(0, 0, 0, 0)
      pr = lookup_user_metric(pr_by_user, username) || GithubService::PRResult.new(0, 0, 0, 0)
      review = lookup_user_metric(review_by_user, username) || GithubService::ReviewResult.new(0, 0, 0)
      last_commit_at = lookup_user_metric(last_commit_at_by_user, username) ||
                       lookup_user_metric(fallback_last_commit_at_by_user, username)

      per_student[username] = {
        data_available: true,
        missing_data_flags: [],
        last_commit_at: last_commit_at,
        cbp: {
          commit_count: cbp.commit_count,
          lines_added: cbp.lines_added,
          lines_removed: cbp.lines_removed,
          lines_changed: cbp.lines_changed
        },
        pr: {
          opened_count: pr.opened_count,
          merged_count: pr.merged_count,
          open_count: pr.open_count,
          avg_merge_hours: pr.avg_merge_hours
        },
        review: {
          review_count: review.review_count,
          approvals: review.approvals,
          changes_requested: review.changes_requested
        }
      }
    end

    cbp_totals = per_student.values.map { |metric| metric[:cbp] }
    pr_totals = per_student.values.map { |metric| metric[:pr] }
    review_totals = per_student.values.map { |metric| metric[:review] }

    {
      data_available: true,
      repo: repo,
      cbp: {
        total_commits: cbp_totals.sum { |metric| metric[:commit_count].to_i },
        total_lines_changed: cbp_totals.sum { |metric| metric[:lines_changed].to_i },
        active_contributors: cbp_totals.count { |metric| metric[:commit_count].to_i.positive? }
      },
      pr: {
        opened_count: pr_totals.sum { |metric| metric[:opened_count].to_i },
        merged_count: pr_totals.sum { |metric| metric[:merged_count].to_i },
        open_count: pr_totals.sum { |metric| metric[:open_count].to_i },
        avg_merge_hours: average(pr_totals.filter_map { |metric| metric[:avg_merge_hours].to_f.positive? ? metric[:avg_merge_hours].to_f : nil })
      },
      review: {
        review_count: review_totals.sum { |metric| metric[:review_count].to_i },
        approvals: review_totals.sum { |metric| metric[:approvals].to_i },
        changes_requested: review_totals.sum { |metric| metric[:changes_requested].to_i }
      },
      missing_data_flags: [],
      per_student: per_student
    }
  rescue StandardError
    empty_team_github_metrics(repo: repo, missing_data_flags: ["github_query_failed"])
  end

  def build_last_commit_only(team_service:, repo:, sprint:, students:, cache_version: nil, force_refresh: false, missing_data_flags: [])
    return empty_team_github_metrics(missing_data_flags: ["repo_missing"]) if repo.blank?
    return empty_team_github_metrics(repo: repo, missing_data_flags: ["token_unavailable"]) unless team_service.available?

    start_date = (sprint.start_date || Date.current.beginning_of_month).beginning_of_day
    end_date = (sprint.end_date || Date.current.end_of_month).end_of_day
    fallback_end_date = end_date.respond_to?(:to_date) ? end_date.to_date : Date.current
    fallback_start_date = fallback_end_date - 180.days

    last_commit_at_by_user = team_service.last_commit_at_by_user(
      repo,
      start_date,
      end_date,
      cache_version: cache_version,
      force_refresh: force_refresh
    )
    fallback_last_commit_at_by_user = team_service.last_commit_at_by_user(
      repo,
      fallback_start_date,
      fallback_end_date,
      cache_version: "#{cache_version}:fallback_last_commit",
      force_refresh: force_refresh
    )

    per_student = {}
    students.each do |student|
      username = student.github_username.to_s
      next if username.blank?

      last_commit_at = lookup_user_metric(last_commit_at_by_user, username) ||
                       lookup_user_metric(fallback_last_commit_at_by_user, username)

      per_student[username] = {
        data_available: false,
        missing_data_flags: Array(missing_data_flags),
        last_commit_at: last_commit_at,
        cbp: { commit_count: 0, lines_added: 0, lines_removed: 0, lines_changed: 0 },
        pr: { opened_count: 0, merged_count: 0, open_count: 0, avg_merge_hours: 0.0 },
        review: { review_count: 0, approvals: 0, changes_requested: 0 }
      }
    end

    {
      data_available: false,
      repo: repo,
      cbp: { total_commits: 0, total_lines_changed: 0, active_contributors: 0 },
      pr: { opened_count: 0, merged_count: 0, open_count: 0, avg_merge_hours: 0.0 },
      review: { review_count: 0, approvals: 0, changes_requested: 0 },
      missing_data_flags: Array(missing_data_flags),
      per_student: per_student
    }
  rescue StandardError => e
    Rails.logger.warn("Last commit fallback failed for team repo #{repo}: #{e.class} - #{e.message}")
    empty_team_github_metrics(repo: repo, missing_data_flags: Array(missing_data_flags))
  end

  def lookup_user_metric(metrics, username)
    return nil if metrics.blank? || username.blank?

    return metrics[username] if metrics.key?(username)

    normalized_target = normalized_github_username(username)
    return nil if normalized_target.blank?

    metrics.each do |key, value|
      return value if normalized_github_username(key) == normalized_target
    end

    nil
  end

  def normalized_github_username(value)
    value.to_s.strip.sub(/\A@/, "").downcase
  end

  def status_cache_version_for(team:, sprint: nil)
    student_fingerprint = team.students.order(:id).map do |student|
      [
        student.id,
        normalized_github_username(student.github_username),
        student.updated_at&.to_i
      ].join(":")
    end.join("|")

    student_digest = Digest::SHA256.hexdigest(student_fingerprint)[0, 16]

    parts = [
      "semester:#{@semester.id}",
      "team:#{team.id}:#{team.updated_at.to_i}",
      "students:#{student_digest}"
    ]

    if sprint
      parts << "sprint:#{sprint.id}:#{sprint.updated_at.to_i}"
      parts << "window:#{sprint.start_date}:#{sprint.end_date}"
    end

    parts.join("|")
  end

  def empty_student_github_metrics(missing_data_flags: ["repo_or_token_missing"], data_available: false)
    {
      data_available: !!data_available,
      missing_data_flags: Array(missing_data_flags),
      last_commit_at: nil,
      cbp: { commit_count: 0, lines_added: 0, lines_removed: 0, lines_changed: 0 },
      pr: { opened_count: 0, merged_count: 0, open_count: 0, avg_merge_hours: 0.0 },
      review: { review_count: 0, approvals: 0, changes_requested: 0 }
    }
  end

  def empty_team_github_metrics(repo: nil, missing_data_flags: [])
    {
      data_available: false,
      repo: repo,
      cbp: { total_commits: 0, total_lines_changed: 0, active_contributors: 0 },
      pr: { opened_count: 0, merged_count: 0, open_count: 0, avg_merge_hours: 0.0 },
      review: { review_count: 0, approvals: 0, changes_requested: 0 },
      missing_data_flags: Array(missing_data_flags),
      per_student: {}
    }
  end

  def score_cbp(commit_count:, lines_changed:)
    commit_component = [commit_count.to_i * 12.0, 60.0].min
    churn_component = [(lines_changed.to_f / 40.0), 40.0].min
    bounded_score(commit_component + churn_component)
  end

  def score_pr(opened_count:, merged_count:, open_count:, avg_merge_hours:)
    opened_component = [opened_count.to_i * 8.0, 35.0].min
    merged_component = [merged_count.to_i * 12.0, 45.0].min
    open_penalty = [open_count.to_i * 4.0, 20.0].min

    merge_velocity_bonus = if avg_merge_hours.to_f.positive?
      [(36.0 / avg_merge_hours.to_f) * 20.0, 20.0].min
    else
      0.0
    end

    bounded_score(opened_component + merged_component + merge_velocity_bonus - open_penalty)
  end

  def score_review(review_count:, approvals:, changes_requested:)
    review_component = [review_count.to_i * 8.0, 55.0].min
    approval_component = [approvals.to_i * 10.0, 35.0].min
    changes_penalty = [changes_requested.to_i * 3.0, 20.0].min

    bounded_score(review_component + approval_component - changes_penalty)
  end

  def github_band_for(score)
    return "Strong" if score >= 85
    return "Solid" if score >= 70
    return "Watch" if score >= 55

    "At Risk"
  end

  def bounded_score(score)
    [[score.to_f, 0.0].max, 100.0].min.round(1)
  end

  def average(values)
    list = Array(values)
    return 0.0 if list.blank?

    (list.sum.to_f / list.size).round(1)
  end

  def ku_band_for(score)
    return "Healthy" if score >= 85
    return "Watch" if score >= 70

    "At Risk"
  end

  def pp_band_for(score)
    return "High Completion" if score >= 80
    return "Moderate Completion" if score >= 60

    "Low Completion"
  end

  def percentage(numerator, denominator)
    return 0.0 if denominator.to_i <= 0

    (numerator.to_f / denominator.to_f) * 100.0
  end

  # Recognizes completed tasks assigned to a specific sprint.
  # Supports GitHub Project status names such as "Done Archive (Sprint 2)"
  # so archived tasks are included in sprint progress calculations.
  def done_in_sprint_status?(status, sprint_name)
    return false if status.blank? || sprint_name.blank?

    sprint_number = sprint_name.to_s[/\d+/]
    return false if sprint_number.blank?

    normalized = status.to_s.strip.downcase

    normalized.match?(
      /\A(?:done in sprint\s*#{Regexp.escape(sprint_number)}|done archive\s*\(sprint\s*#{Regexp.escape(sprint_number)}\))\z/
    )
  end

  # Identify completed tasks across all sprints, including tasks
  # moved into sprint-specific archive columns on the GitHub board.
  def done_in_any_sprint_status?(status)
    return false if status.blank?

    normalized = status.to_s.strip.downcase

    normalized.match?(
      /\A(?:done in sprint\s*\d+|done archive\s*\(sprint\s*\d+\))\z/
    )
  end

  def sprint_in_progress?(sprint)
    today = Date.current
    start_date = sprint.start_date&.to_date
    end_date = sprint.end_date&.to_date
    return false if start_date.blank? || end_date.blank?

    today >= start_date && today <= end_date
  end

  def numeric_field(card, *candidate_names)
    fields = card.fields || {}
    key = fields.keys.find do |field_name|
      candidate_names.any? { |candidate| field_name.to_s.casecmp(candidate).zero? }
    end

    # Fallback matching handles light naming variations such as
    # "Time Taken (hrs)" vs "Time Taken".
    if key.blank?
      normalized_candidates = candidate_names.map { |name| normalize_field_name(name) }
      key = fields.keys.find do |field_name|
        normalized_field = normalize_field_name(field_name)
        normalized_candidates.any? do |candidate|
          normalized_field.include?(candidate) || candidate.include?(normalized_field)
        end
      end
    end

    return 0.0 if key.blank?

    fields[key].to_f
  end

  def estimate_value(card)
    numeric_field(
      card,
      "Time Estimate",
      "Time Estiamte",
      "Estimate",
      "Estimated Hours",
      "Estimated Time"
    )
  end

  # Retrieve actual hours worked from a GitHub Project task.
  # Include "Completed Time" to support the custom field used
  # by the current team's project board.
  def spent_value(card)
    numeric_field(
      card,
      "Time Spent",
      "Time Taken",
      "Hours Spent",
      "Spent",
      "Actual Time",
      "Time Logged",
      "Completed Time"
    )
  end

  def card_time_sample(card)
    {
      title: card.title,
      status: card.status,
      assignees: Array(card.assignees),
      estimate_field: matched_field_name(card, "Time Estimate", "Time Estiamte", "Estimate", "Estimated Hours", "Estimated Time"),
      estimate_value: estimate_value(card),
      taken_field: matched_field_name(card, "Time Spent", "Time Taken", "Hours Spent", "Spent", "Actual Time", "Time Logged"),
      taken_value: spent_value(card)
    }
  end

  def matched_field_name(card, *candidate_names)
    fields = card.fields || {}
    key = fields.keys.find do |field_name|
      candidate_names.any? { |candidate| field_name.to_s.casecmp(candidate).zero? }
    end

    if key.blank?
      normalized_candidates = candidate_names.map { |name| normalize_field_name(name) }
      key = fields.keys.find do |field_name|
        normalized_field = normalize_field_name(field_name)
        normalized_candidates.any? do |candidate|
          normalized_field.include?(candidate) || candidate.include?(normalized_field)
        end
      end
    end

    key
  end

  def normalize_field_name(value)
    value.to_s.downcase.gsub(/[^a-z0-9]/, "")
  end

  def cards_for_sprint(cards, sprint)
    matching_cards = cards.select { |card| card_matches_sprint?(card, sprint) }

    return matching_cards unless latest_sprint_in_semester?(sprint)

    # Include untagged current work alongside sprint-specific completed cards.
    current_work = cards.select do |card|
      status = card.status

      next false unless backlog_status?(status) ||
                        todo_status?(status) ||
                        in_progress_status?(status) ||
                        done_status?(status)

      card_sprint_number(card).blank?
    end

    (matching_cards + current_work).uniq
  end

  def assignee_matches_student?(card, student)
    return false if card.blank? || student.blank?

    assignees = Array(card.assignees).map(&:to_s).reject(&:blank?)
    return false if assignees.empty?

    target_username = normalized_github_username(student.github_username)
    if target_username.present?
      normalized_assignees = assignees.map { |value| normalized_github_username(value) }
      return true if normalized_assignees.include?(target_username)
    end

    student_name = student.full_name.to_s.strip.downcase
    student_name.present? && assignees.any? { |value| value.to_s.strip.downcase == student_name }
  end

  def normalize_status_token(status)
    status.to_s.downcase.gsub(/[^a-z0-9]/, "")
  end

  def backlog_status?(status)
    normalize_status_token(status) == "backlog"
  end

  def todo_status?(status)
    normalize_status_token(status) == "todo"
  end

  def in_progress_status?(status)
    normalize_status_token(status) == "inprogress"
  end

  def done_status?(status)
    normalize_status_token(status) == "done"
  end

  def archived_status?(status)
    normalize_status_token(status) == "archived"
  end

  def active_status?(status)
    backlog_status?(status) || todo_status?(status) || in_progress_status?(status)
  end

  def count_by_status_group(count_map)
    count_map.sum do |status, count|
      yield(status) ? count.to_i : 0
    end
  end

  # Identify the currently active sprint using its scheduled dates.
  # Untagged GitHub Project tasks are associated with the active sprint
  # rather than a future sprint that has not started.
  def latest_sprint_in_semester?(sprint)
    return false if sprint.blank? || sprint.start_date.blank? || sprint.end_date.blank?

    today = Time.zone.today

    sprint.start_date.to_date <= today &&
      sprint.end_date.to_date >= today
  end

  def card_matches_sprint?(card, sprint)
    return false if card.blank? || sprint.blank?

    status = card.status.to_s

    # Sprint-specific completed statuses take priority over metadata.
    if done_in_any_sprint_status?(status)
      return done_in_sprint_status?(status, sprint.name)
    end

    sprint_number = sprint.name.to_s[/\d+/]
    return false if sprint_number.blank?

    card_sprint_number(card) == sprint_number
  end

  def card_sprint_number(card)
    return nil if card.blank?

    fields = card.fields || {}
    fields.each do |field_name, value|
      next unless field_name.to_s.match?(/sprint|iteration/i)

      value_str = value.to_s.downcase
      number = value_str[/\d+/]
      return number if number.present?
    end

    nil
  end
end
