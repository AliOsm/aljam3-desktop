# frozen_string_literal: true

# A controllable OS accessibility preference without changing the host's settings.
module MotionPreference
  def self.set(app, reduced:)
    app.define_singleton_method(:reduced_motion?) { reduced }
    app.refresh_motion_preference
  end

  def self.system(app)
    app.singleton_class.remove_method(:reduced_motion?)
    app.refresh_motion_preference
  end
end
