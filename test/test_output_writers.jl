"""
Run a coarse thermal bubble simulation and save the output to NetCDF at the
10th time step. Then read back the output and test that it matches the model's
state.
"""
function run_thermal_bubble_netcdf_tests(arch)
    Nx, Ny, Nz = 16, 16, 16
    Lx, Ly, Lz = 100, 100, 100
    Δt = 6

    model = BasicModel(N=(Nx, Ny, Nz), L=(Lx, Ly, Lz), architecture=arch, ν=4e-2, κ=4e-2)

    # Add a cube-shaped warm temperature anomaly that takes up the middle 50%
    # of the domain volume.
    i1, i2 = round(Int, Nx/4), round(Int, 3Nx/4)
    j1, j2 = round(Int, Ny/4), round(Int, 3Ny/4)
    k1, k2 = round(Int, Nz/4), round(Int, 3Nz/4)
    model.tracers.T.data[i1:i2, j1:j2, k1:k2] .+= 0.01

    nc_writer = NetCDFOutputWriter(dir=".", prefix="test_", frequency=10, padding=1)
    push!(model.output_writers, nc_writer)

    time_step!(model, 10, Δt)

    u = read_output(nc_writer, "u", 10)
    v = read_output(nc_writer, "v", 10)
    w = read_output(nc_writer, "w", 10)
    T = read_output(nc_writer, "T", 10)
    S = read_output(nc_writer, "S", 10)

    @test all(u .≈ Array(parentdata(model.velocities.u)))
    @test all(v .≈ Array(parentdata(model.velocities.v)))
    @test all(w .≈ Array(parentdata(model.velocities.w)))
    @test all(T .≈ Array(parentdata(model.tracers.T)))
    @test all(S .≈ Array(parentdata(model.tracers.S)))
end

function run_jld2_file_splitting_tests(arch)
    model = BasicModel(N=(16, 16, 16), L=(1, 1, 1))

    u(model) = Array(model.velocities.u.data.parent)
    fields = Dict(:u => u)

    function fake_bc_init(file, model)
        file["boundary_conditions/fake"] = π
    end

    ow = JLD2OutputWriter(model, fields; dir=".", prefix="test", frequency=1,
                          init=fake_bc_init, including=[:grid],
                          max_filesize=200KiB, force=true)
    push!(model.output_writers, ow)

    # 531 KiB of output will be written which should get split into 3 files.
    time_step!(model, 10, 1)

    # Test that files has been split according to size as expected.
    @test filesize("test_part1.jld2") > 200KiB
    @test filesize("test_part2.jld2") > 200KiB
    @test filesize("test_part3.jld2") < 200KiB

    for n in string.(1:3)
        filename = "test_part" * n * ".jld2"
        jldopen(filename, "r") do file
            # Test to make sure all files contain structs from `including`.
            @test file["grid/Nx"] == 16

            # Test to make sure all files contain info from `init` function.
            @test file["boundary_conditions/fake"] == π
        end

        # Leave test directory clean.
        rm(filename)
    end
end

"""
Run two coarse rising thermal bubble simulations and make sure that when
restarting from a checkpoint, the restarted simulation matches the non-restarted
simulation numerically.
"""
function run_thermal_bubble_checkpointer_tests(arch)
    Nx, Ny, Nz = 16, 16, 16
    Lx, Ly, Lz = 100, 100, 100
    Δt = 6

    true_model = BasicModel(N=(Nx, Ny, Nz), L=(Lx, Ly, Lz), ν=4e-2, κ=4e-2, architecture=arch)

    # Add a cube-shaped warm temperature anomaly that takes up the middle 50%
    # of the domain volume.
    i1, i2 = round(Int, Nx/4), round(Int, 3Nx/4)
    j1, j2 = round(Int, Ny/4), round(Int, 3Ny/4)
    k1, k2 = round(Int, Nz/4), round(Int, 3Nz/4)
    true_model.tracers.T.data[i1:i2, j1:j2, k1:k2] .+= 0.01

    checkpointed_model = deepcopy(true_model)

    time_step!(true_model, 9, Δt)

    checkpointer = Checkpointer(checkpointed_model; frequency=5, force=true)
    push!(checkpointed_model.output_writers, checkpointer)

    # Checkpoint should be saved as "checkpoint5.jld" after the 5th iteration.
    time_step!(checkpointed_model, 5, Δt)

    # Remove all knowledge of the checkpointed model.
    checkpointed_model = nothing

    restored_model = restore_from_checkpoint("checkpoint5.jld2")

    time_step!(restored_model, 4, Δt; init_with_euler=false)

    # Now the true_model and restored_model should be identical.
    @test all(restored_model.velocities.u.data      .≈ true_model.velocities.u.data)
    @test all(restored_model.velocities.v.data      .≈ true_model.velocities.v.data)
    @test all(restored_model.velocities.w.data      .≈ true_model.velocities.w.data)
    @test all(restored_model.tracers.T.data         .≈ true_model.tracers.T.data)
    @test all(restored_model.tracers.S.data         .≈ true_model.tracers.S.data)
    @test all(restored_model.timestepper.Gⁿ.Gu.data .≈ true_model.timestepper.Gⁿ.Gu.data)
    @test all(restored_model.timestepper.Gⁿ.Gv.data .≈ true_model.timestepper.Gⁿ.Gv.data)
    @test all(restored_model.timestepper.Gⁿ.Gw.data .≈ true_model.timestepper.Gⁿ.Gw.data)
    @test all(restored_model.timestepper.Gⁿ.GT.data .≈ true_model.timestepper.Gⁿ.GT.data)
    @test all(restored_model.timestepper.Gⁿ.GS.data .≈ true_model.timestepper.Gⁿ.GS.data)
end

@testset "Output writers" begin
    println("Testing output writers...")

    for arch in archs
         @testset "NetCDF [$(typeof(arch))]" begin
             println("  Testing NetCDF output writer [$(typeof(arch))]...")
             run_thermal_bubble_netcdf_tests(arch)
         end

        @testset "JLD2 [$(typeof(arch))]" begin
            println("  Testing JLD2 output writer [$(typeof(arch))]...")
            run_jld2_file_splitting_tests(arch)
        end

        @testset "Checkpointer [$(typeof(arch))]" begin
            println("  Testing Checkpointer [$(typeof(arch))]...")
            run_thermal_bubble_checkpointer_tests(arch)
        end
    end
end
