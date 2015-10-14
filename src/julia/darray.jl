using DistributedArrays

# FixMe! Right now the MPI workers are deduced from the DArrays, but if a DArray is distributed on fewer workers that what consistutes the MPI world, then this approach will fail.

function toback{S<:StridedMatrix}(A::DArray{Float64,2,S})
    rs = Array(Any, size(A.chunks))
    @sync for p in eachindex(A.chunks)
        ind = A.indexes[p]
        @async rs[p] = remotecall(A.pids[p]) do
            lA = localpart(A)
            AlA = Elemental.DistMatrix(Float64)
            zeros!(AlA, size(A)...)
            for j = 1:size(lA, 2)
                for i = 1:size(lA, 1)
                    queueUpdate(AlA, start(ind[1]) + i - 1, start(ind[2]) + j - 1, lA[i,j])
                end
            end
            processQueues(AlA)
            AlA
        end
    end
    return rs
end

function tofront(r::Base.Matrix)
    tt = [remotecall(() -> typeof(fetch(rr)), rr.where) for rr in r]
    rType = fetch(tt[1])
    if rType <: ElementalMatrix
        tt = [remotecall(() -> size(fetch(rr)), rr.where) for rr in r]
        mn = fetch(tt[1])
        A = dzeros(mn, Int[r[i,j].where for i = 1:size(r, 1), j = 1:size(r, 2)])

        @sync for p in eachindex(r)
            ind = A.indexes[p]
            rr = r[p]
            @async remotecall_wait(r[p].where) do
                rrr = fetch(rr)
                lA = localpart(A)
                for j = 1:size(lA, 2)
                    for i = 1:size(lA, 1)
                        queuePull(rrr, start(ind[1]) + i - 1, start(ind[2]) + j - 1)
                    end
                end
                processPullQueue(rrr, lA)
            end
        end
    elseif rType <: Exception
        throw(fetch(r[1]))
    else
        error("Remote type was $rType and is not handled yet")
    end
    return A
end

function (\){T<:BlasFloat,S}(A::DArray{T,2,S}, B::DArray{T,2,S})
    rA = toback(A)
    rB = toback(B)
    pidsAB = union(A.pids, B.pids)
    rvals = Array(Any, length(pidsAB))
    @sync for i = 1:length(pidsAB)
        @async rvals[i] = remotecall_wait((t1,t2) -> solve!(fetch(t1), fetch(t2)), pidsAB[i], rA[i], rB[i])
    end
    return tofront(reshape(rvals, size(B.chunks)))
end

function eigvals{T<:BlasFloat}(A::Hermitian{T,DArray{T,2,Array{T,2}}})
    rA = toback(A.data)
    rvals = Array(Any, size(A.data.chunks))
    uplo = A.uplo == 'U' ? UPPER : LOWER
    @sync for j = 1:size(rvals, 2)
        for i = 1:size(rvals, 1)
            @async rvals[i,j] = remotecall_wait(t -> eigvalsHermitian(uplo, fetch(t)), rA[i,j].where, rA[i,j])
        end
    end
    return tofront(rvals)
end

function svdvals{T<:BlasFloat}(A::DArray{T,2})
    rA = toback(A)
    rvals = Array(Any, size(A.chunks))
    @sync for j = 1:size(rvals, 2)
        for i = 1:size(rvals, 1)
            @async rvals[i,j] = remotecall_wait(t -> svdvals(fetch(t)), rA[i,j].where, rA[i,j])
        end
    end
    return tofront(rvals)
end

for (elty, ext) in ((:ElInt, :i),
                    (:Float32, :s),
                    (:Float64, :d),
                    (:Complex64, :c),
                    (:Complex128, :z))
    @eval begin
# Andreas: Just saw this one. It is almost identical to the one I wrote above, but I don't think that we can return a Elemental array beacause it has to live on the MPI cluster and cannot live on the "front end".
# It is assumed that the DArray is distributed over MPI.COMM_WORLD
        function DistSparseMatrix(::Type{$elty}, DA::DistributedArrays.DArray)
            npr, npc = size(procs(DA))
            if npr*npc != MPI.Comm_size(MPI.COMM_WORLD)
                error("Used non MPI.COMM_WORLD DArray for DistSparseMatrix, as procs(DA)=($npr,$npc) is incompatible with MPI.Comm_size(MPI.COMM_WORLD)=$(MPI.Comm_size(MPI.COMM_WORLD))")
            end

            m, n = size(DA)
            A = DistSparseMatrix($elty, m, n)
            @sync begin
                for id in workers()
                    let A = A, DA = DA
                        @async remotecall_fetch(id) do
                            rows, cols = DistributedArrays.localindexes(DA)
                            i,j,v = findnz(DistributedArrays.localpart(DA))
                            gi, gj, gv = (i.+(first(rows)-1), j.+(first(cols)-1), v)
                            numLocal = length(gi)
                            reserve(A,numLocal)
                            for s=1:numLocal
                                queueUpdate(A,gi[s],gj[s],v[s])
                            end
                        end
                    end
                end
            end
            processQueues(A)
            return A
        end
    end
end