require "digest"
class StatusSnapshotCoordinator
  REFRESH_TIMEOUT = 30.minutes

  def initialize(semester:, user:)
    @semester = semester
    @user = user
  end

  def cache_key
    sprint_fingerprint = @semester.sprints.order(:id).map do |sprint|
        [
        sprint.id,
        sprint.name,
        sprint.start_date,
        sprint.end_date
        ].join(":")
    end.join("|")

    digest = Digest::SHA256.hexdigest(sprint_fingerprint)

    "status_snapshot:v3:#{@semester.id}:#{@user.id}:#{digest}"
    end

  def refresh_key
    "#{cache_key}:refreshing"
  end

  def snapshot
    Rails.cache.read(cache_key)
  end

  def refreshing?
    Rails.cache.read(refresh_key).present?
  end

  def request_refresh(force_refresh: false)
    acquired = Rails.cache.write(
      refresh_key,
      Time.current,
      expires_in: REFRESH_TIMEOUT,
      unless_exist: true
    )

    return false unless acquired

    begin
      job = StatusSnapshotJob.perform_later(
        @semester.id,
        @user.id,
        cache_key,
        force_refresh
      )

      unless job
        Rails.cache.delete(refresh_key)
        return false
      end

      true
    rescue StandardError
      Rails.cache.delete(refresh_key)
      raise
    end
  end
end