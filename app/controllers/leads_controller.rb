class LeadsController < ApplicationController
  def index
    @leads = Lead.order(created_at: :desc)
  end

  def show
    @lead = Lead.find(params[:id])
  end
end
