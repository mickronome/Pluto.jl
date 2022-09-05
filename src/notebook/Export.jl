import Pkg
using Base64
using HypertextLiteral
import URIs

const default_binder_url = "https://mybinder.org/v2/gh/fonsp/pluto-on-binder/v$(string(PLUTO_VERSION))"

const cdn_version_override = nothing
# const cdn_version_override = "2a48ae2"

if cdn_version_override !== nothing
    @warn "Reminder to fonsi: Using a development version of Pluto for CDN assets. The binder button might not work. You should not see this on a released version of Pluto." cdn_version_override
end

function cdnified_editor_html(;
        version::Union{Nothing,VersionNumber,AbstractString}=nothing, 
        pluto_cdn_root::Union{Nothing,AbstractString}=nothing,
    )
    should_use_bundled_cdn = version ∈ (nothing, PLUTO_VERSION) && pluto_cdn_root === nothing
    
    something(
        if should_use_bundled_cdn
            try
                original = read(project_relative_path("frontend-dist", "editor.html"), String)
    
                replace_with_cdn(original) do url
                    # Because parcel creates filenames with a hash in them, we can check if the file exists locally to make sure that everything is in order.
                    @assert isfile(project_relative_path("frontend-dist", url))
                    
                    URIs.resolvereference("https://cdn.jsdelivr.net/gh/fonsp/Pluto.jl@$(string(PLUTO_VERSION))/frontend-dist/", url) |> string
                end
            catch e
                @warn "Could not use bundled CDN version of editor.html. You should only see this message if you are using a fork of Pluto." exception=(e,catch_backtrace())
                nothing
            end
        end,
        let
            original = read(project_relative_path("frontend", "editor.html"), String)

            cdn_root = something(pluto_cdn_root, "https://cdn.jsdelivr.net/gh/fonsp/Pluto.jl@$(something(cdn_version_override, string(something(version, PLUTO_VERSION))))/frontend/")
            @debug "Using CDN for Pluto assets:" cdn_root
    
            replace_with_cdn(original) do url
                URIs.resolvereference(cdn_root, url) |> string
            end
        end
    )
end

"""
See [PlutoSliderServer.jl](https://github.com/JuliaPluto/PlutoSliderServer.jl) if you are interested in exporting notebooks programatically.
"""
function generate_html(;
        version::Union{Nothing,VersionNumber,AbstractString}=nothing, 
        pluto_cdn_root::Union{Nothing,AbstractString}=nothing,
        
        notebookfile_js::AbstractString="undefined", 
        statefile_js::AbstractString="undefined", 
        
        slider_server_url_js::AbstractString="undefined", 
        binder_url_js::AbstractString=repr(default_binder_url),
        
        disable_ui::Bool=true, 
        preamble_html_js::AbstractString="undefined",
        notebook_id_js::AbstractString="undefined", 
        isolated_cell_ids_js::AbstractString="undefined",

        static_javascript::AbstractString="",
        static_css::AbstractString="",
        header_html::AbstractString="",
    )::String

    cdnified = cdnified_editor_html(; version, pluto_cdn_root)

    result = replace_at_least_once(
        replace_at_least_once(cdnified, 
            "<meta name=\"pluto-insertion-spot-meta\">" => 
            """
            $(header_html)
            <meta name=\"pluto-insertion-spot-meta\">
            """),
        "<meta name=\"pluto-insertion-spot-parameters\">" => 
        """
        <script data-pluto-file="launch-parameters">
        window.pluto_notebook_id = $(notebook_id_js);
        window.pluto_isolated_cell_ids = $(isolated_cell_ids_js);
        window.pluto_notebookfile = $(notebookfile_js);
        window.pluto_disable_ui = $(disable_ui ? "true" : "false");
        window.pluto_slider_server_url = $(slider_server_url_js);
        window.pluto_binder_url = $(binder_url_js);
        window.pluto_statefile = $(statefile_js);
        window.pluto_preamble_html = $(preamble_html_js);
        </script>
        $(static_javascript != "" ? "<script src=\"$(static_javascript)\" type=\"module\" defer></script>"   : "")
        $(static_css        != "" ? "<link rel=\"stylesheet\" href=\"$(static_css)\" type=\"text/css\">" : "")
        <meta name=\"pluto-insertion-spot-parameters\">
        """
    )

    return result
end

function replace_at_least_once(s, pair)
    from, to = pair
    @assert occursin(from, s)
    replace(s, pair)
end


function generate_html(notebook; kwargs...)::String
    state = notebook_to_js(notebook)

    notebookfile_js = let
        notebookfile64 = base64encode() do io
            save_notebook(io, notebook)
        end

        "\"data:text/julia;charset=utf-8;base64,$(notebookfile64)\""
    end

    statefile_js = let
        statefile64 = base64encode() do io
            pack(io, state)
        end

        "\"data:;base64,$(statefile64)\""
    end
    
    fm = frontmatter(notebook)
    header_html = isempty(fm) ? "" : frontmatter_html(fm) # avoid loading HypertextLiteral if there is no frontmatter
    
    # We don't set `notebook_id_js` because this is generated by the server, the option is only there for funky setups.
    generate_html(; statefile_js, notebookfile_js, header_html, kwargs...)
end


const frontmatter_writers = (
    ("title", x -> @htl("""
        <title>$(x)</title>
        """)),
    ("description", x -> @htl("""
        <meta name="description" content=$(x)>
        """)),
    ("tags", x -> x isa Vector ? @htl("$((
        @htl("""
            <meta property="og:article:tag" content=$(t)>
            """)
        for t in x
    ))") : nothing),
)


const _og_properties = ("title", "type", "description", "image", "url", "audio", "video", "site_name", "locale", "locale:alternate", "determiner")

const _default_frontmatter = Dict{String, Any}(
    "type" => "article",
    # Note: these defaults are skipped when there is no frontmatter at all.
)

function frontmatter_html(frontmatter::Dict{String,Any}; default_frontmatter::Dict{String,Any}=_default_frontmatter)::String
    d = merge(default_frontmatter, frontmatter)
    repr(MIME"text/html"(), 
        @htl("""$((
            f(d[key])
            for (key, f) in frontmatter_writers if haskey(d, key)
        ))$((
            @htl("""<meta property=$("og:$(key)") content=$(val)>
            """)
            for (key, val) in d if key in _og_properties
        ))"""))
end





replace_substring(s::String, sub::SubString, newval::AbstractString) = *(
	SubString(s, 1, prevind(s, sub.offset + 1, 1)), 
	newval, 
	SubString(s, nextind(s, sub.offset + sub.ncodeunits))
)

const source_pattern = r"\s(?:src|href)=\"(.+?)\""

function replace_with_cdn(cdnify::Function, s::String, idx::Integer=1)
	next_match = match(source_pattern, s, idx)
	if next_match === nothing
		s
	else
		url = only(next_match.captures)
		if occursin("//", url)
			# skip this one
			replace_with_cdn(cdnify, s, nextind(s, next_match.offset))
		else
			replace_with_cdn(cdnify, replace_substring(
				s,
				url,
				cdnify(url)
			))
		end
	end
end
