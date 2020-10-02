require 'yaml'
require 'open3'
require 'pathname'
require 'fileutils'

def get_env_variable(key)
	return (ENV[key] == nil || ENV[key] == "") ? nil : ENV[key]
end

ac_flutter_project_dir = get_env_variable("AC_FLUTTER_PROJECT_DIR") || abort('Missing Flutter project path.')
ac_flutter_build_mode = get_env_variable("AC_FLUTTER_BUILD_MODE") || "release"
ac_output_folder = get_env_variable("AC_OUTPUT_DIR") || abort('Missing output folder.')

def run_command(command)
    puts "@@[command] #{command}"
    unless system(command)
      exit $?.exitstatus
    end
end

run_command("flutter channel beta")
run_command("flutter upgrade")
run_command("flutter config --enable-web")
run_command("flutter build web --#{ac_flutter_build_mode}")

puts "Copying artifacts to output folder..."
web_output_folder="#{ac_flutter_project_dir}/build/web"

FileUtils.copy_entry web_output_folder, "#{ac_output_folder}"

puts "Exporting AC_FLUTTER_WEB_PATH=#{ac_output_folder}/web"

open(ENV['AC_ENV_FILE_PATH'], 'a') { |f|
    f.puts "AC_FLUTTER_WEB_PATH=#{ac_output_folder}/web"
}

exit 0