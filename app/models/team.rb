class Team < ApplicationRecord
  belongs_to :semester
  has_many :student_teams, dependent: :destroy
  has_many :students, through: :student_teams
  # TA assignments
  has_many :user_teams, dependent: :destroy
  has_many :assigned_tas, through: :user_teams, source: :user

  validates :name, presence: true
  # Possible for there to be multiple same team name - go by semester
  validates :name, uniqueness: { scope: :semester_id, message: "already exists for this semester" }

end
