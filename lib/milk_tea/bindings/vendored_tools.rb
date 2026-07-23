# frozen_string_literal: true

module MilkTea
  module VendoredTools
    def self.all(root: MilkTea.root)
      [
        *VendoredTracy.all_tools(root:),
      ]
    end

    def self.build_all!(root: MilkTea.root)
      data = MilkTea.writable_root_for(root)
      results = all(root:).map do |tool|
        binary = tool.build!
        install = tool.install_path(root: data)
        FileUtils.mkdir_p(File.dirname(install))
        FileUtils.cp(binary, install)
        FileUtils.chmod(0o755, install)
        { tool: tool, binary: install }
      end
      results
    end
  end
end
