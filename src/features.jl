"""
    Features can be extracted from QueueRecords.
They always return a FeatureValue, which allows the encoding of discrete / continuous / missing values,
which can also be forced to a Float64.
"""
abstract type AbstractFeature end

baremodule FeatureState
    # good
    const GOOD        = 0 # value is perfectly A-okay

    # caution
    const INSUF_HIST  = 1 # value best-guess was made due to insufficient history (ex, acceleration set to zero due to one timestamp)

    # bad (in these cases fval.v is typically set to NaN as well)
    const MISSING     = 2 # value is missing (no car in front, etc.)
    const CENSORED_HI = 3 # value is past an operating threshold
    const CENSORED_LO = 4 # value is below an operating threshold
end

struct FeatureValue
    v::Float64 # feature value
    i::Int # used to encode

    FeatureValue(v::Float64, i::Int=FeatureState.GOOD) = new(v, i)
end

is_feature_valid(fval::FeatureValue) = fval.i == FeatureState.GOOD || fval.i == FeatureState.INSUF_HIST
Base.convert(::Type{Float64}, fval::FeatureValue) = fval.v

const SYMBOL_TO_FEATURE = Dict{Symbol, AbstractFeature}()

is_symbol_a_feature(sym::Symbol) = haskey(SYMBOL_TO_FEATURE, sym)
allfeatures() = values(SYMBOL_TO_FEATURE)
symbol2feature(sym::Symbol) = SYMBOL_TO_FEATURE[sym]

###

function generate_feature_functions(
    name::String,
    sym::Symbol,
    inherent_type::DataType,
    units::String;
    lowerbound::Float64=-Inf,
    upperbound::Float64=Inf,
    can_be_missing::Bool=false,
    censor_lo::Float64=NaN,
    censor_hi::Float64=NaN,
    history::Int=1,
    )

    for feature in values(SYMBOL_TO_FEATURE)
        @assert(sym != Symbol(feature), "symb: $name -> $feature")
    end
    @assert(lowerbound ≤ upperbound)

    feature_name = Symbol("Feature_" * name)
    const_name   = Symbol(uppercase(name))
    sym_feature  = Meta.quot(sym)

    @eval begin
        export $const_name
        immutable $feature_name <: AbstractFeature end
        const       $const_name  = ($feature_name)()
        units(          ::$feature_name)  = $(units)
        inherent_type(  ::$feature_name)  = $(inherent_type)
        lowerbound(     ::$feature_name)  = $(lowerbound)
        upperbound(     ::$feature_name)  = $(upperbound)
        can_be_missing( ::$feature_name)  = $(can_be_missing)
        history(        ::$feature_name)  = $(history)
        Base.Symbol(    ::$feature_name)  = $sym_feature
        SYMBOL_TO_FEATURE[Symbol($const_name)] = $const_name
    end
end

function _get_feature_derivative_backwards{S,D,I,R}(
    f::AbstractFeature,
    rec::EntityQueueRecord{S,D,I},
    roadway::R,
    vehicle_index::Int,
    pastframe::Int=0,
    frames_back::Int=1,
    )

    id = rec[pastframe][vehicle_index].id

    retval = FeatureValue(0.0, FeatureState.INSUF_HIST)
    pastframe2 = pastframe - frames_back

    if pastframe_inbounds(rec, pastframe) && pastframe_inbounds(rec, pastframe2)

        veh_index_curr = vehicle_index
        veh_index_prev = findfirst(rec[pastframe2], id)

        if veh_index_prev != 0
            curr = convert(Float64, get(f, rec, roadway, veh_index_curr, pastframe))
            past = convert(Float64, get(f, rec, roadway, veh_index_prev, pastframe2))
            Δt = get_elapsed_time(rec, pastframe2, pastframe)
            retval = FeatureValue((curr - past) / Δt)
        end
    end

    return retval
end

###

generate_feature_functions("PosFt", :posFt, Float64, "m")
generate_feature_functions("PosFyaw", :posFyaw, Float64, "rad")
generate_feature_functions("Speed", :speed, Float64, "m/s")
generate_feature_functions("VelFs", :velFs, Float64, "m/s")
generate_feature_functions("VelFt", :velFt, Float64, "m/s")

generate_feature_functions("Acc", :acc, Float64, "m/s^2")
function Base.get{S,D,I,R}(::Feature_Acc, rec::EntityQueueRecord{S,D,I}, roadway::R, vehicle_index::Int, pastframe::Int=0)
    _get_feature_derivative_backwards(SPEED, rec, roadway, vehicle_index, pastframe)
end
generate_feature_functions("AccFs", :accFs, Float64, "m/s²")
function Base.get{S,D,I,R}(::Feature_AccFs, rec::EntityQueueRecord{S,D,I}, roadway::R, vehicle_index::Int, pastframe::Int=0)
    _get_feature_derivative_backwards(VELFS, rec, roadway, vehicle_index, pastframe)
end
generate_feature_functions("AccFt", :accFt, Float64, "m/s²")
function Base.get{S,D,I,R}(::Feature_AccFt, rec::EntityQueueRecord{S,D,I}, roadway::R, vehicle_index::Int, pastframe::Int=0)
    _get_feature_derivative_backwards(VELFT, rec, roadway, vehicle_index, pastframe)
end
generate_feature_functions("Jerk", :jerk, Float64, "m/s³")
function Base.get{S,D,I,R}(::Feature_Jerk, rec::EntityQueueRecord{S,D,I}, roadway::R, vehicle_index::Int, pastframe::Int=0)
    _get_feature_derivative_backwards(ACC, rec, roadway, vehicle_index, pastframe)
end
generate_feature_functions("JerkFs", :jerkFs, Float64, "m/s³")
function Base.get{S,D,I,R}(::Feature_JerkFs, rec::EntityQueueRecord{S,D,I}, roadway::R, vehicle_index::Int, pastframe::Int=0)
    _get_feature_derivative_backwards(ACCFS, rec, roadway, vehicle_index, pastframe)
end
generate_feature_functions("JerkFt", :jerkFt, Float64, "m/s³")
function Base.get{S,D,I,R}(::Feature_JerkFt, rec::EntityQueueRecord{S,D,I}, roadway::R, vehicle_index::Int, pastframe::Int=0)
    _get_feature_derivative_backwards(ACCFT, rec, roadway, vehicle_index, pastframe)
end

###

"""
    get_neighbor_index_fore(scene::Scene, vehicle_index::Int, roadway::Roadway)
Return the index of the vehicle that is in the same lane as scene[vehicle_index] and
in front of it with the smallest distance along the lane

    The method will search on the current lane first, and if no vehicle is found it
    will continue to travel along the lane following next_lane(lane, roadway).
    If no vehicle is found within `max_distance_fore,` a value of 0 is returned instead.
"""
struct NeighborLongitudinalResult
    ind::Int # index in scene of the neighbor
    Δs::Float64 # positive distance along lane between vehicles' positions
end

###

"""
    get_first_collision(scene, roadway)

Returns the first pair of entity indeces that are colliding.
"""
function get_first_collision{S,D,I,R}(scene::EntityFrame{S,D,I}, roadway::R)::Tuple{Int,Int}
    for (i,vehA) in enumerate(scene)
        for j in i+1 : length(scene)
            vehB = scene[j]
            if is_colliding(vehA, vehB, roadway)
                return (i,j)
            end
        end
    end
    return (0,0)
end

"""
    has_collision(scene, roadway)

Whether there is at least one collision in the scene.
"""
function has_collision{S,D,I,R}(scene::EntityFrame{S,D,I}, roadway::R)
    first_col = get_first_collision(scene, roadway)
    return first_col != (0,0)
end

##

"""
    LeadFollowRelationships

A simple struct which maps a vehicle_index to the vehicle index of the leading or trailing vehicle, based
on get_neighbor_fore and get_neighbor_rear.

Automatic construction requires that get_neighbor_fore and get_neighbor_rear be implemented
for your S,D,I,R combination.
"""
struct LeadFollowRelationships
    index_fore::Vector{Int}
    index_rear::Vector{Int}
end

function Base.:(==)(A::LeadFollowRelationships, B::LeadFollowRelationships)
    return A.index_fore == B.index_fore &&
           A.index_rear == B.index_rear
end

function LeadFollowRelationships{S,D,I,R}(scene::EntityFrame{S,D,I}, roadway::R, vehicle_indices::AbstractVector{Int} = 1:length(scene))

    nvehicles = length(scene)
    index_fore = zeros(Int, nvehicles)
    index_rear = zeros(Int, nvehicles)

    for vehicle_index in vehicle_indices
        index_fore[vehicle_index] = get_neighbor_fore(scene, vehicle_index, roadway).ind
        index_rear[vehicle_index] = get_neighbor_rear(scene, vehicle_index, roadway).ind
    end

    return LeadFollowRelationships(index_fore, index_rear)
end