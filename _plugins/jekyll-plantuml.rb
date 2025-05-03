require 'jekyll'
require 'liquid'
require 'digest'
require 'fileutils'

class Jekyll::PlantumlBlock < Liquid::Block
  def initialize(tag_name, markup, tokens)
    super
    @html = (markup or '').strip
  end

  def render(context)
    site = context.registers[:site]
    body = super.to_s
    name = Digest::MD5.hexdigest(body)
    unless File.exist?(File.join(site.dest, "uml/#{name}.svg"))
      uml = File.join(site.source, "uml/#{name}.uml")
      svg = File.join(site.source, "uml/#{name}.svg")
      if File.exist?(svg)
        puts "File #{svg} already exists (#{File.size(svg)} bytes)"
      else
        FileUtils.mkdir_p(File.dirname(uml))
        File.write(uml, ["@startuml\n", body, "\n@enduml"].join)
        unless system("plantuml -tsvg #{uml} 2>&1")
          raise "PlantUML failed to compile the following snippet (see logs above):\n#{body}\n"
        end
        site.static_files << Jekyll::StaticFile.new(
          site, site.source, 'uml', "#{name}.svg"
        )
        puts "\nFile #{svg} created (#{File.size(svg)} bytes)"
      end
    end
    "<p><img src='#{site.baseurl}/uml/#{name}.svg' class='plantuml'></p>"
  end
end

Liquid::Template.register_tag('plantuml', Jekyll::PlantumlBlock)