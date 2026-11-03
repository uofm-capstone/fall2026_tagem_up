class TeamsController < ApplicationController
  before_action :authenticate_user!
  before_action :set_team, only: [:show, :edit, :update, :destroy, :add_member, :remove_member]

  load_and_authorize_resource class: Team

  
  
  def index
    if current_user.ta?
      # Get the semester associated with the TA's assigned teams.
      @current_semester = current_user.assigned_teams
                                      .joins(:semester)
                                      .first&.semester

      if @current_semester
        session[:last_viewed_semester_id] = @current_semester.id
      end

      @teams = current_user.assigned_teams
                          .where(semester_id: @current_semester&.id)

      @students = Student.joins(:teams)
                        .where(teams: { id: @teams.select(:id) })
                        .distinct
                        .order(:full_name)

    elsif current_user.student?
      @current_semester = Semester.find_by(
        id: session[:last_viewed_semester_id]
      )
      @teams = current_user.student ? current_user.student.teams : Team.none
      @students = Student.none

    else
      @current_semester = Semester.find_by(
        id: session[:last_viewed_semester_id]
      )
      @teams = Team.where(semester_id: @current_semester&.id)
      @students = Student.where(
        semester_id: @current_semester&.id
      ).order(:full_name)
    end

    @team = Team.new
    render :index
  end



  def show
    authorize! :read, @team
    @team_members = @team.students
    render :show
  end

  def new
    @team = Team.new
  end

  
  def create
    @team = Team.new(team_params)
    @current_semester = Semester.find_by(
      id: session[:last_viewed_semester_id]
    )

    unless @current_semester
      return redirect_to semesters_path, alert: "Please select a semester first."
    end

    @team.semester = @current_semester
    authorize! :create, @team

    if @team.save
      # Automatically assign a newly created team to its TA.
      if current_user.ta?
        current_user.user_teams.create!(team: @team)
      end

      redirect_to teams_path, notice: "Team was successfully created."
    else
      if current_user.ta?
        @teams = current_user.assigned_teams.where(
          semester_id: @current_semester.id
        )

        @students = Student.joins(:teams)
                          .where(teams: { id: @teams.select(:id) })
                          .distinct
                          .order(:full_name)
      else
        @teams = Team.where(semester_id: @current_semester.id)
        @students = Student.where(
          semester_id: @current_semester.id
        ).order(:full_name)
      end

      render :index, status: :unprocessable_entity
    end
  end


  def import_csv
    semester_id = session[:last_viewed_semester_id]
    return redirect_to(teams_path, alert: "Select a semester before importing students.") if semester_id.blank?

    semester = Semester.find_by(id: semester_id)
    return redirect_to(teams_path, alert: "Semester not found.") unless semester

    authorize! :create, Team

    file = params[:student_csv]
    result = StudentRosterImportService.new(semester: semester, file: file).import

    if result[:ok]
      redirect_to teams_path, notice: result[:message]
    else
      redirect_to teams_path, alert: result[:message]
    end
  end

  def edit
    @semesters = Semester.all
    @students = Student.where.not(id: @team.student_ids)
  end
  
  def update
    if @team.update(team_params)
      redirect_to teams_path, notice: 'Team was successfully updated.'
    else
      @current_semester = session[:last_viewed_semester_id]
      @students = Student.where.not(id: @team.student_ids)
      # Re-render the whole index so the modal + errors appear like "new"
      @teams = Team.all
      render :index, status: :unprocessable_entity
    end
  end

  def destroy
    @team.destroy
    redirect_to teams_path, notice: 'Team was successfully deleted.'
  end

  def add_member
    authorize! :update, @team
    @student = Student.find(params[:student_id])

    student_team = StudentTeam.new(student: @student, team: @team)

    if student_team.save
      redirect_to teams_path, notice: 'Member was successfully added to the team.'
    else
      redirect_to teams_path, alert: 'Failed to add member to the team.'
    end
  end

  def remove_member
    authorize! :update, @team
    @student_team = StudentTeam.find_by(student_id: params[:student_id], team_id: @team.id)

    if @student_team&.destroy
      redirect_to edit_team_path(@team), notice: 'Member was successfully removed from the team.'
    else
      redirect_to edit_team_path(@team), alert: 'Failed to remove member from the team.'
    end
  end

  private

  def set_team
    @team = Team.find(params[:id])

    if current_user.ta? &&
      !current_user.assigned_teams.exists?(
        id: @team.id,
        semester_id: session[:last_viewed_semester_id]
      )
      raise CanCan::AccessDenied
    end
  end

  def team_params
    params.require(:team).permit(:name, :description, :github_token, :repo_url, :project_board_url, :timesheet_url, :client_notes_url, student_ids: [])
  end
end