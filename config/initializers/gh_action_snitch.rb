# config/initializers/gh_action_snitch.rb
# https://guides.rubyonrails.org/error_reporting.html
# https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-commands#setting-an-error-message
#
# Annotates errors for GitHub Actions if running in that environment.
class GHActionSnitchErrorSubscriber
  def report(error, handled:, severity:, context:, source: nil)
    if ENV["GITHUB_ACTIONS"] == "true"
      error_location = ActiveSupport::BacktraceCleaner.new.clean_locations(error.backtrace_locations)&.first
      file = error_location&.path
      line = error_location&.lineno

      annotation_details = []
      annotation_details << "file=#{file}" if file.present?
      annotation_details << "line=#{line}" if line.present?

      record_prefix = context[:record].present? ? "#{context[:record].class.name} (#{context[:record].to_param}) - " : ""

      puts "\n::error #{annotation_details.join(",")}::#{record_prefix}#{error.detailed_message(highlight: false)}\n"
    end
    raise error
  end
end

Rails.error.subscribe(GHActionSnitchErrorSubscriber.new)
