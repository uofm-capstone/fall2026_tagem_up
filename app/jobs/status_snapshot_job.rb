class StatusSnapshotJob < ApplicationJob
  queue_as :default

  def perform(semester_id, user_id, cache_key, force_refresh = false)
    semester = Semester.find(semester_id)
    user = User.find(user_id)

    payload = StatusSnapshotService.new(
      semester: semester,
      user: user,
      force_refresh: force_refresh
    ).call

    Rails.cache.write(
      cache_key,
      {
        payload: payload,
        built_at: Time.current
      }
    )

    Rails.cache.delete("#{cache_key}:error")

    Rails.logger.info(
      "Status snapshot generated for semester #{semester_id}"
    )

  rescue StandardError => e
    Rails.cache.write(
      "#{cache_key}:error",
      Time.current,
      expires_in: 30.minutes
    )

    Rails.logger.error(
      "Status snapshot failed for semester #{semester_id}: #{e.class}"
    )

    raise
  ensure
    Rails.cache.delete("#{cache_key}:refreshing")
  end
end
