# == Schema Information
#
# Table name: sprints
#
#  id          :bigint           not null, primary key
#  end_date    :datetime
#  name        :text
#  start_date  :datetime
#  created_at  :datetime         not null
#  updated_at  :datetime         not null
#  semester_id :bigint
#
# Indexes
#
#  index_sprints_on_semester_id  (semester_id)
#
# Foreign Keys
#
#  fk_rails_...  (semester_id => semesters.id)
#
class Sprint < ApplicationRecord
  belongs_to :semester

  validates :name, presence: true
  validates :start_date, presence: true
  validates :end_date, presence: true

  validate :valid_date_range

  private

  def valid_date_range
    return if start_date.blank? || end_date.blank?

    if end_date < start_date
      errors.add(:end_date, "must be on or after the start date")
    end
  end
end