# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/aljam3/ui/updates"

class UpdateNotificationsTest < Minitest::Test
  def test_running_from_a_download_explains_how_to_install_before_retrying
    Dir.mktmpdir("aljam3-update-notice-") do |directory|
      updates = File.join(directory, "updates")
      FileUtils.mkdir_p(updates)
      receipt = File.join(updates, "result.txt")
      File.write(receipt, "move_to_applications")
      updater = Struct.new(:directory, :version) do
        def supported? = false
      end.new(updates, "0.0.1")
      context = Object.new.extend(Aljam3::UI::UpdateScreen)
      workers = []
      notifications = Aljam3::Notifications.new
      context.instance_variable_set(:@workers, workers)
      context.instance_variable_set(:@notifications, notifications)
      begin
        Aljam3::Updates.stub(:new, updater) { context.setup_updates(directory) }
        notice = notifications.find(:update_result)
        assert notice.fetch(:error)
        assert_nil notice.fetch(:remaining)
        assert_includes notice.fetch(:detail), "Applications"
        assert_includes notice.fetch(:detail), "Finder"
        refute_includes notice.fetch(:detail), "كتبك وموضع القراءة محفوظة"
        refute File.exist?(receipt)
      ensure
        workers.each(&:close)
      end
    end
  end
end
