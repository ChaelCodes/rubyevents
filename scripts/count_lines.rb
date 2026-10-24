#!/usr/bin/env ruby

# Counts lines of code per directory.
#
# Standalone, no Rails required:
#   $ ruby scripts/count_lines.rb
#
# Also works via the Rails runner, like the other scripts here:
#   $ bin/rails runner scripts/count_lines.rb
#
# Rows come out in DIRECTORIES order, not sorted by size, so the list reads as
# an intentional narrative. Each entry declares a `language`, and may declare a
# `tests` counterpart, which is counted as its own row beneath the entry.

require "find"

ROOT = File.expand_path("..", __dir__)

# Directories to skip while walking a tree.
SKIP_DIRS = %w[.git node_modules tmp log vendor public/assets .yarn].freeze

# Each language gets its own column. Files are matched to a language by
# extension; anything that can't be matched falls back to the entry's declared
# `language`, which is how extensionless files like bin/mcp_server get counted.
LANGUAGES = {
  "ruby" => %w[.rb .rake],
  "yaml" => %w[.yml .yaml],
  "json" => %w[.json],
  "markdown" => %w[.md]
}.freeze

# Libraries the agent-session tooling depends on. Just the list for now -
# nothing reads this yet, so decide how to count them later.
#
# path => the installed gem root, not lib/, so what to count stays open
# upstream => GitHub repo, for test suites the gems don't ship
GEMS = [
  {name: "ruby_llm", path: "/usr/local/bundle/gems/ruby_llm-1.15.0", upstream: "crmne/ruby_llm"},
  {name: "schematist", path: "/usr/local/bundle/gems/schematist-1.1.0", upstream: "crmne/schematist"},
  {name: "yerba", path: "/usr/local/bundle/gems/yerba-0.9.0-aarch64-linux-gnu", upstream: "marcoroth/yerba"},
  {name: "yt", path: "/usr/local/bundle/gems/yt-0.34.1", upstream: "nullscreen/yt"},
  {name: "geocoder", path: "/usr/local/bundle/bundler/gems/geocoder-aa134e37153f", upstream: "alexreisner/geocoder"},
  {name: "parallel", path: "/usr/local/bundle/gems/parallel-1.28.0", upstream: "grosser/parallel"}
].freeze

# label => what we call it in the output table
# paths => the files or directories to count; may be a glob
# language => fallback for files whose extension isn't recognised
DIRECTORIES = [
  {label: "copilot-setup-steps.yml", language: "yaml", reasoning: "Builds the environment the agent runs in", paths: [".github/workflows/copilot-setup-steps.yml"]},
  {label: "AGENTS.md", language: "markdown", reasoning: "The brief an agent session opens with - commands, conventions, and the data import flow", paths: ["AGENTS.md"]},
  {label: ".mcp.json", language: "json", reasoning: "Wires up the MCP server for agents", paths: [".mcp.json"]},
  {label: "bin/mcp_server", language: "ruby", reasoning: "MCP Server", paths: ["bin/mcp_server"]},
  {label: "MCP tools", language: "ruby", reasoning: "The hand-written RubyLLM tools", paths: ["app/tools"]},
  {label: "app/clients", language: "ruby", reasoning: "The HTTP clients every fetching MCP tool wraps", paths: ["app/clients"]},
  {label: "lib/generators", language: "ruby", paths: ["lib/generators"], tests: "test/lib/generators"},
  {label: "skills/event-data", language: "markdown", paths: [".agents/skills/event-data"]},
  {label: "validate.rake", language: "ruby", reasoning: "Runs all the validations on the data files", paths: ["lib/tasks/validate.rake"]},
  {label: "Static::Validators", language: "ruby", reasoning: "Validations that the yaml matches our rules - some autocorrect!", paths: ["app/models/static/validators"], tests: "test/models/static/validators"},
  {label: "Schemas", language: "ruby", reasoning: "Ensure the correct keys and data in the right format is used", paths: ["app/schemas"]},
  {label: "Static classes", language: "ruby", reasoning: "The Static classes the validators use", paths: ["app/models/static/*.rb"]},
  {label: "Yerbafile", language: "yaml", reasoning: "Formatting rules for data/**/*.yml, but it also validates against lib/schemas and prunes defaulted keys", paths: ["Yerbafile"]},
  {label: "seed.rake", language: "ruby", reasoning: "db:seed:all projects validated YAML into the database - the import the smoke test exercises", paths: ["lib/tasks/seed.rake"]},
  {label: "seed_test.rb", language: "ruby", reasoning: "The Data Smoke Test - proves the seeded DB matches the YAML", paths: ["test/tasks/seed_test.rb"]},
  {label: ".github/workflows/ci.yml", language: "yaml", paths: [".github/workflows/ci.yml"]},
  {label: "labeler.yml", language: "yaml", reasoning: "Glob-based labels: data changes and event assets", paths: [".github/labeler.yml"]},
  {label: "labeler workflow", language: "yaml", reasoning: "Also patch-greps videos.yml for an added video_provider and tags it published", paths: [".github/workflows/labeler.yml"]},
  {label: "pull_request_template.md", language: "markdown", paths: [".github/pull_request_template.md"]}
].freeze

DIRECTORIES.each do |entry|
  next if LANGUAGES.key?(entry[:language])

  warn "#{entry[:label]}: #{entry[:language].inspect} is not one of #{LANGUAGES.keys.join(", ")}"
end

Count = Struct.new(:files, :lines, :by_language) do
  def add(other)
    self.files += other.files
    self.lines += other.lines
    other.by_language.each { |language, count| by_language[language] += count }
    self
  end

  def [](language)
    by_language[language]
  end
end

def blank_count
  Count.new(0, 0, Hash.new(0))
end

# Extension match, falling back to the entry's declared language.
def detect_language(path, fallback)
  extension = File.extname(path)

  LANGUAGES.find { |_, extensions| extensions.include?(extension) }&.first || fallback
end

# How a list of paths is shown in the PATH column.
def display_paths(paths)
  return paths.first if paths.size < 2

  dirs = paths.map { |path| File.dirname(path) }

  return "#{dirs.first}/ (#{paths.size} files)" if dirs.uniq.one?

  "#{paths.first} (+#{paths.size - 1} more)"
end

def walk_files(absolute)
  files = []

  Find.find(absolute) do |path|
    basename = File.basename(path)

    if File.directory?(path)
      Find.prune if path != absolute && SKIP_DIRS.include?(basename)
      next
    end

    files << path if File.file?(path)
  end

  files
end

# Expands a path that may be a glob, a file, or a directory into concrete files.
def resolve(relative)
  Dir.glob(File.join(ROOT, relative)).flat_map do |absolute|
    File.directory?(absolute) ? walk_files(absolute) : absolute
  end
end

def count_lines_in(paths, fallback)
  total = blank_count

  paths.each do |path|
    begin
      contents = File.read(path, encoding: "UTF-8")
    rescue Encoding::UndefinedConversionError, ArgumentError
      next # binary file
    end

    lines = contents.each_line.count

    total.files += 1
    total.lines += lines
    total.by_language[detect_language(path, fallback)] += lines
  end

  total
end

# Counts an entry, tolerating missing paths. Returns nil if none of them exist.
def count_paths(paths, fallback)
  files = paths.flat_map { |relative| resolve(relative) }
  missing = paths.reject { |relative| resolve(relative).any? }

  warn "skipped #{missing.join(", ")} (not found)" if missing.any?

  return nil if files.empty?

  count_lines_in(files, fallback)
end

def pluralize(count, noun, plural = nil)
  "#{count} #{(count == 1) ? noun : (plural || "#{noun}s")}"
end

# 13619 => "13,619"
def delimit(number)
  number.to_s.reverse.scan(/\d{1,3}/).join(",").reverse
end

# Each entry is a row, plus a row for its optional test counterpart.
items = DIRECTORIES.flat_map do |entry|
  rows = [{name: entry[:label], path: display_paths(entry[:paths]), count: count_paths(entry[:paths], entry[:language])}]

  if entry[:tests]
    rows << {name: "  tests", path: entry[:tests], count: count_paths([entry[:tests]], entry[:language])}
  end

  rows
end

name_width = items.map { |item| item[:name].length }.max + 2
path_width = items.map { |item| item[:path].length }.max + 2

column_width = items.map { |item| item[:count]&.lines.to_s.length || 0 }.max
language_width = LANGUAGES.keys.map { |language| [language.length, column_width].max }.max + 2

render = lambda do |item|
  if item[:count].nil?
    puts " #{item[:name].ljust(name_width)}#{"(missing)".ljust(path_width)}"
    return
  end

  cells = LANGUAGES.keys.map { |language| delimit(item[:count][language]).rjust(language_width) }
  cells << delimit(item[:count].lines).rjust(language_width)

  puts " #{item[:name].ljust(name_width)}#{item[:path].ljust(path_width)}#{cells.join}"
end

number_columns = LANGUAGES.size + 1

rule = " #{"-" * name_width}#{"-" * path_width}#{"-" * language_width * number_columns}"

puts
puts "Tracked paths by language"
puts
puts " #{"NAME".ljust(name_width)}#{"PATH".ljust(path_width)}#{LANGUAGES.keys.map { |language| language.upcase.rjust(language_width) }.join}#{"TOTAL".rjust(language_width)}"
puts rule

grand_total = blank_count

items.each do |item|
  render.call(item)
  grand_total.add(item[:count]) if item[:count]
end

puts rule
puts " #{"TOTAL".ljust(name_width)}#{"".ljust(path_width)}#{LANGUAGES.keys.map { |language| delimit(grand_total[language]).rjust(language_width) }.join}#{delimit(grand_total.lines).rjust(language_width)}"
puts
puts "#{pluralize(DIRECTORIES.size, "entry", "entries")} covering #{pluralize(grand_total.files, "file")} and #{delimit(grand_total.lines)} lines."
puts "Unrecognised extensions fall back to the entry's declared language."
puts "Paths resolve against the repo root, so this works from any directory."
puts
