class HealthController < ActionController::API
  def show
    render json: {
      ok: true,
      widget_count: Widget.count,
    }
  end
end
