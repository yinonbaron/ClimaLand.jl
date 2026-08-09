import CairoMakie
import NCDatasets
import Printf

function usage()
    println(
        stderr,
        "usage: julia plot_de_hai_carbon_pools.jl PUBLISHED_DIR LOCAL_DIR OUTPUT_PNG",
    )
end

function load_series(directory, variable)
    path = joinpath(directory, "$(variable)_daily.nc")
    return NCDatasets.NCDataset(path) do dataset
        time = Float64.(vec(dataset["time"].var[:]))
        values = Float64.(vec(dataset[variable][:]))
        return (; time, values)
    end
end

function main(arguments)
    if length(arguments) != 3
        usage()
        return 2
    end

    published_directory, local_directory, output_path = arguments
    pools = (
        ("cLeaf", "Green leaf carbon"),
        ("cbLeaf", "Brown leaf carbon"),
        ("cStem", "Stem carbon"),
        ("cRoot", "Root carbon"),
        ("cLitter", "Litter carbon"),
        ("cSoil", "Soil carbon"),
    )

    CairoMakie.set_theme!(
        CairoMakie.Theme(
            fontsize = 18,
            Axis = (
                xgridcolor = (:gray, 0.18),
                ygridcolor = (:gray, 0.18),
            ),
        ),
    )
    figure = CairoMakie.Figure(size = (1600, 1200))
    axes = CairoMakie.Axis[]

    for (index, (variable, title)) in enumerate(pools)
        row = div(index - 1, 2) + 1
        column = mod(index - 1, 2) + 1
        published = load_series(published_directory, variable)
        local_run = load_series(local_directory, variable)
        published.time == local_run.time ||
            error("time coordinates differ for $variable")

        years = 2000 .+ (published.time .- 1) ./ 365.25
        axis = CairoMakie.Axis(
            figure[row, column];
            title,
            xlabel = row == 3 ? "Year" : "",
            ylabel = "kg C m⁻²",
            xticks = 2000:2:2012,
        )
        push!(axes, axis)
        CairoMakie.lines!(
            axis,
            years,
            published.values;
            color = :navy,
            linewidth = 2.5,
            label = "Published",
        )
        CairoMakie.lines!(
            axis,
            years,
            local_run.values;
            color = :darkorange,
            linewidth = 2,
            linestyle = :dash,
            label = "Local v2.0 quick start",
        )

        maximum_difference = maximum(abs.(local_run.values .- published.values))
        Printf.@printf(
            "%-8s published=[%.8g, %.8g] local=[%.8g, %.8g] max_abs_difference=%.8g\n",
            variable,
            extrema(published.values)...,
            extrema(local_run.values)...,
            maximum_difference,
        )
    end

    CairoMakie.axislegend(axes[1]; position = :rt)
    CairoMakie.Label(
        figure[0, 1:2],
        "DE-Hai daily carbon pools: published benchmark vs local CLASSIC v2.0 run";
        fontsize = 25,
        font = :bold,
    )
    CairoMakie.save(output_path, figure; px_per_unit = 1.25)
    println("saved $output_path")
    return 0
end

exit(main(ARGS))
