;; Ballot Counting Contract
;; Secure vote casting and transparent result tallying

;; Constants
(define-constant CONTRACT_OWNER tx-sender)
(define-constant ERR_UNAUTHORIZED (err u200))
(define-constant ERR_VOTING_CLOSED (err u201))
(define-constant ERR_ALREADY_VOTED (err u202))
(define-constant ERR_NOT_ELIGIBLE (err u203))
(define-constant ERR_INVALID_CANDIDATE (err u204))
(define-constant ERR_ELECTION_NOT_FOUND (err u205))
(define-constant ERR_ELECTION_ENDED (err u206))
(define-constant ERR_INVALID_ELECTION_ID (err u207))
(define-constant ERR_RESULTS_NOT_READY (err u208))

;; Data Variables
(define-data-var current-election-id uint u0)
(define-data-var total-elections uint u0)
(define-data-var voting-open bool false)
(define-data-var results-published bool false)

;; Data Maps
(define-map elections
    { election-id: uint }
    {
        name: (string-ascii 100),
        description: (string-ascii 500),
        start-block: uint,
        end-block: uint,
        is-active: bool,
        total-votes: uint,
        candidate-count: uint,
        created-by: principal
    }
)

(define-map candidates
    { election-id: uint, candidate-id: uint }
    {
        name: (string-ascii 100),
        description: (string-ascii 300),
        vote-count: uint,
        is-active: bool
    }
)

(define-map votes
    { election-id: uint, voter-address: principal }
    {
        candidate-id: uint,
        vote-timestamp: uint,
        vote-block: uint,
        vote-hash: (buff 32)
    }
)

(define-map voter-participation
    { voter-address: principal }
    {
        elections-voted: (list 10 uint),
        total-votes-cast: uint,
        last-vote-block: uint
    }
)

(define-map election-results
    { election-id: uint }
    {
        winner-candidate-id: uint,
        total-valid-votes: uint,
        results-finalized: bool,
        finalized-block: uint,
        vote-distribution: (list 20 { candidate-id: uint, votes: uint })
    }
)

;; Admin Functions
(define-public (create-election (name (string-ascii 100)) (description (string-ascii 500)) (duration-blocks uint))
    (let
        (
            (election-id (+ (var-get total-elections) u1))
            (start-block stacks-block-height)
            (end-block (+ stacks-block-height duration-blocks))
        )
        (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
        (asserts! (> duration-blocks u0) ERR_INVALID_ELECTION_ID)
        
        ;; Create new election
        (map-set elections
            { election-id: election-id }
            {
                name: name,
                description: description,
                start-block: start-block,
                end-block: end-block,
                is-active: true,
                total-votes: u0,
                candidate-count: u0,
                created-by: tx-sender
            }
        )
        
        ;; Update counters
        (var-set total-elections election-id)
        (var-set current-election-id election-id)
        
        (ok election-id)
    )
)

(define-public (add-candidate (election-id uint) (name (string-ascii 100)) (description (string-ascii 300)))
    (let
        (
            (election-data (unwrap! (map-get? elections { election-id: election-id }) ERR_ELECTION_NOT_FOUND))
            (candidate-id (+ (get candidate-count election-data) u1))
        )
        (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
        (asserts! (get is-active election-data) ERR_ELECTION_ENDED)
        (asserts! (< stacks-block-height (get start-block election-data)) ERR_VOTING_CLOSED)
        
        ;; Add candidate
        (map-set candidates
            { election-id: election-id, candidate-id: candidate-id }
            {
                name: name,
                description: description,
                vote-count: u0,
                is-active: true
            }
        )
        
        ;; Update election candidate count
        (map-set elections
            { election-id: election-id }
            (merge election-data { candidate-count: candidate-id })
        )
        
        (ok candidate-id)
    )
)

(define-public (set-voting-status (status bool))
    (begin
        (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
        (var-set voting-open status)
        (ok status)
    )
)

(define-public (end-election (election-id uint))
    (let
        (
            (election-data (unwrap! (map-get? elections { election-id: election-id }) ERR_ELECTION_NOT_FOUND))
        )
        (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
        (asserts! (get is-active election-data) ERR_ELECTION_ENDED)
        
        ;; End the election
        (map-set elections
            { election-id: election-id }
            (merge election-data { is-active: false })
        )
        
        ;; Create basic results entry
        (map-set election-results
            { election-id: election-id }
            {
                winner-candidate-id: u0,
                total-valid-votes: (get total-votes election-data),
                results-finalized: true,
                finalized-block: stacks-block-height,
                vote-distribution: (list)
            }
        )
        
        (ok true)
    )
)

;; Core Voting Functions
(define-public (cast-vote (election-id uint) (candidate-id uint))
    (let
        (
            (voter-address tx-sender)
            (election-data (unwrap! (map-get? elections { election-id: election-id }) ERR_ELECTION_NOT_FOUND))
            (candidate-data (unwrap! (map-get? candidates { election-id: election-id, candidate-id: candidate-id }) ERR_INVALID_CANDIDATE))
            (vote-timestamp stacks-block-height)
            (vote-hash (keccak256 (concat (concat (unwrap-panic (to-consensus-buff? voter-address)) (unwrap-panic (to-consensus-buff? candidate-id))) (unwrap-panic (to-consensus-buff? vote-timestamp)))))
        )
        ;; Validate voting conditions
        (asserts! (var-get voting-open) ERR_VOTING_CLOSED)
        (asserts! (get is-active election-data) ERR_ELECTION_ENDED)
        (asserts! (>= stacks-block-height (get start-block election-data)) ERR_VOTING_CLOSED)
        (asserts! (<= stacks-block-height (get end-block election-data)) ERR_VOTING_CLOSED)
        (asserts! (get is-active candidate-data) ERR_INVALID_CANDIDATE)
        
        ;; Check if voter has already voted in this election
        (asserts! (is-none (map-get? votes { election-id: election-id, voter-address: voter-address })) ERR_ALREADY_VOTED)
        
        ;; Record the vote
        (map-set votes
            { election-id: election-id, voter-address: voter-address }
            {
                candidate-id: candidate-id,
                vote-timestamp: vote-timestamp,
                vote-block: stacks-block-height,
                vote-hash: vote-hash
            }
        )
        
        ;; Update candidate vote count
        (map-set candidates
            { election-id: election-id, candidate-id: candidate-id }
            (merge candidate-data { vote-count: (+ (get vote-count candidate-data) u1) })
        )
        
        ;; Update election total votes
        (map-set elections
            { election-id: election-id }
            (merge election-data { total-votes: (+ (get total-votes election-data) u1) })
        )
        
        ;; Update voter participation
        (update-voter-participation voter-address election-id)
        
        (ok vote-hash)
    )
)

;; Helper Functions
(define-private (update-voter-participation (voter-address principal) (election-id uint))
    (let
        (
            (current-participation (default-to
                { elections-voted: (list), total-votes-cast: u0, last-vote-block: u0 }
                (map-get? voter-participation { voter-address: voter-address })
            ))
            (updated-elections (unwrap! (as-max-len? (append (get elections-voted current-participation) election-id) u10) false))
        )
        (map-set voter-participation
            { voter-address: voter-address }
            {
                elections-voted: updated-elections,
                total-votes-cast: (+ (get total-votes-cast current-participation) u1),
                last-vote-block: stacks-block-height
            }
        )
        true
    )
)

;; Simple helper function to get candidate vote count
(define-private (get-candidate-votes (election-id uint) (candidate-id uint))
    (match (map-get? candidates { election-id: election-id, candidate-id: candidate-id })
        candidate-data (get vote-count candidate-data)
        u0
    )
)

;; Public function to determine winner (manual process)
(define-public (set-election-winner (election-id uint) (winner-candidate-id uint))
    (let
        (
            (election-data (unwrap! (map-get? elections { election-id: election-id }) ERR_ELECTION_NOT_FOUND))
            (current-results (unwrap! (map-get? election-results { election-id: election-id }) ERR_RESULTS_NOT_READY))
        )
        (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
        (asserts! (not (get is-active election-data)) ERR_ELECTION_ENDED)
        
        ;; Update results with winner
        (map-set election-results
            { election-id: election-id }
            (merge current-results { winner-candidate-id: winner-candidate-id })
        )
        
        (ok winner-candidate-id)
    )
)

;; Read-only Functions
(define-read-only (get-election-info (election-id uint))
    (map-get? elections { election-id: election-id })
)

(define-read-only (get-candidate-info (election-id uint) (candidate-id uint))
    (map-get? candidates { election-id: election-id, candidate-id: candidate-id })
)

(define-read-only (get-vote-info (election-id uint) (voter-address principal))
    (map-get? votes { election-id: election-id, voter-address: voter-address })
)

(define-read-only (get-election-results (election-id uint))
    (map-get? election-results { election-id: election-id })
)

(define-read-only (get-voter-participation (voter-address principal))
    (map-get? voter-participation { voter-address: voter-address })
)

(define-read-only (has-voter-voted (election-id uint) (voter-address principal))
    (is-some (map-get? votes { election-id: election-id, voter-address: voter-address }))
)

(define-read-only (get-current-election-id)
    (var-get current-election-id)
)

(define-read-only (get-total-elections)
    (var-get total-elections)
)

(define-read-only (get-voting-status)
    (var-get voting-open)
)

(define-read-only (is-election-active (election-id uint))
    (match (map-get? elections { election-id: election-id })
        election-data (and 
            (get is-active election-data)
            (>= stacks-block-height (get start-block election-data))
            (<= stacks-block-height (get end-block election-data))
        )
        false
    )
)

(define-read-only (get-contract-owner)
    CONTRACT_OWNER
)


