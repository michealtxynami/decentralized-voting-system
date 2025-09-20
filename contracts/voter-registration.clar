;; Voter Registration Contract
;; Register eligible voters with identity verification

;; Constants
(define-constant CONTRACT_OWNER tx-sender)
(define-constant ERR_UNAUTHORIZED (err u100))
(define-constant ERR_ALREADY_REGISTERED (err u101))
(define-constant ERR_NOT_REGISTERED (err u102))
(define-constant ERR_INVALID_ADDRESS (err u103))
(define-constant ERR_REGISTRATION_CLOSED (err u104))
(define-constant ERR_INVALID_STATUS (err u105))
(define-constant ERR_VERIFICATION_FAILED (err u106))

;; Data Variables
(define-data-var registration-open bool true)
(define-data-var total-registered-voters uint u0)
(define-data-var registration-deadline uint u0)
(define-data-var min-age uint u18)

;; Data Maps
(define-map voters
    { voter-address: principal }
    {
        is-registered: bool,
        registration-block: uint,
        verification-status: (string-ascii 20),
        voter-id: uint,
        age: uint,
        location: (string-ascii 50)
    }
)

(define-map voter-verification
    { voter-address: principal }
    {
        identity-hash: (buff 32),
        verification-timestamp: uint,
        verified-by: principal,
        verification-documents: (list 3 (string-ascii 100))
    }
)

(define-map registration-stats
    { location: (string-ascii 50) }
    {
        total-voters: uint,
        verified-voters: uint,
        pending-voters: uint
    }
)

;; Admin Functions
(define-public (set-registration-status (status bool))
    (begin
        (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
        (var-set registration-open status)
        (ok status)
    )
)

(define-public (set-registration-deadline (deadline uint))
    (begin
        (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
        (asserts! (> deadline stacks-block-height) ERR_INVALID_STATUS)
        (var-set registration-deadline deadline)
        (ok deadline)
    )
)

(define-public (set-minimum-age (age uint))
    (begin
        (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
        (asserts! (>= age u16) ERR_INVALID_STATUS)
        (var-set min-age age)
        (ok age)
    )
)

;; Core Registration Functions
(define-public (register-voter (age uint) (location (string-ascii 50)))
    (let
        (
            (voter-address tx-sender)
            (current-block stacks-block-height)
            (deadline (var-get registration-deadline))
            (voter-id (+ (var-get total-registered-voters) u1))
        )
        (asserts! (var-get registration-open) ERR_REGISTRATION_CLOSED)
        (asserts! (or (is-eq deadline u0) (<= current-block deadline)) ERR_REGISTRATION_CLOSED)
        (asserts! (>= age (var-get min-age)) ERR_INVALID_STATUS)
        (asserts! (is-none (map-get? voters { voter-address: voter-address })) ERR_ALREADY_REGISTERED)
        
        ;; Register the voter
        (map-set voters
            { voter-address: voter-address }
            {
                is-registered: true,
                registration-block: current-block,
                verification-status: "pending",
                voter-id: voter-id,
                age: age,
                location: location
            }
        )
        
        ;; Update total registered voters
        (var-set total-registered-voters voter-id)
        
        ;; Update location statistics
        (update-location-stats location "register")
        
        (ok voter-id)
    )
)

(define-public (verify-voter (voter-address principal) (identity-hash (buff 32)) (documents (list 3 (string-ascii 100))))
    (let
        (
            (voter-data (unwrap! (map-get? voters { voter-address: voter-address }) ERR_NOT_REGISTERED))
            (verification-timestamp stacks-block-height)
        )
        (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
        (asserts! (get is-registered voter-data) ERR_NOT_REGISTERED)
        (asserts! (is-eq (get verification-status voter-data) "pending") ERR_INVALID_STATUS)
        
        ;; Update voter verification status
        (map-set voters
            { voter-address: voter-address }
            (merge voter-data { verification-status: "verified" })
        )
        
        ;; Store verification details
        (map-set voter-verification
            { voter-address: voter-address }
            {
                identity-hash: identity-hash,
                verification-timestamp: verification-timestamp,
                verified-by: tx-sender,
                verification-documents: documents
            }
        )
        
        ;; Update location statistics
        (update-location-stats (get location voter-data) "verify")
        
        (ok true)
    )
)

(define-public (reject-voter (voter-address principal) (reason (string-ascii 100)))
    (let
        (
            (voter-data (unwrap! (map-get? voters { voter-address: voter-address }) ERR_NOT_REGISTERED))
        )
        (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
        (asserts! (get is-registered voter-data) ERR_NOT_REGISTERED)
        (asserts! (is-eq (get verification-status voter-data) "pending") ERR_INVALID_STATUS)
        
        ;; Update voter verification status to rejected
        (map-set voters
            { voter-address: voter-address }
            (merge voter-data { verification-status: "rejected" })
        )
        
        ;; Update location statistics
        (update-location-stats (get location voter-data) "reject")
        
        (ok reason)
    )
)

;; Helper Functions
(define-private (update-location-stats (location (string-ascii 50)) (action (string-ascii 10)))
    (let
        (
            (current-stats (default-to 
                { total-voters: u0, verified-voters: u0, pending-voters: u0 }
                (map-get? registration-stats { location: location })
            ))
        )
        (if (is-eq action "register")
            (map-set registration-stats
                { location: location }
                (merge current-stats { 
                    total-voters: (+ (get total-voters current-stats) u1),
                    pending-voters: (+ (get pending-voters current-stats) u1)
                })
            )
            (if (is-eq action "verify")
                (map-set registration-stats
                    { location: location }
                    (merge current-stats {
                        verified-voters: (+ (get verified-voters current-stats) u1),
                        pending-voters: (- (get pending-voters current-stats) u1)
                    })
                )
                (if (is-eq action "reject")
                    (map-set registration-stats
                        { location: location }
                        (merge current-stats {
                            pending-voters: (- (get pending-voters current-stats) u1)
                        })
                    )
                    false
                )
            )
        )
    )
)

;; Read-only Functions
(define-read-only (get-voter-info (voter-address principal))
    (map-get? voters { voter-address: voter-address })
)

(define-read-only (get-voter-verification (voter-address principal))
    (map-get? voter-verification { voter-address: voter-address })
)

(define-read-only (is-voter-registered (voter-address principal))
    (match (map-get? voters { voter-address: voter-address })
        voter-data (get is-registered voter-data)
        false
    )
)

(define-read-only (is-voter-verified (voter-address principal))
    (match (map-get? voters { voter-address: voter-address })
        voter-data (is-eq (get verification-status voter-data) "verified")
        false
    )
)

(define-read-only (get-total-registered-voters)
    (var-get total-registered-voters)
)

(define-read-only (get-registration-status)
    (var-get registration-open)
)

(define-read-only (get-registration-deadline)
    (var-get registration-deadline)
)

(define-read-only (get-minimum-age)
    (var-get min-age)
)

(define-read-only (get-location-stats (location (string-ascii 50)))
    (map-get? registration-stats { location: location })
)

(define-read-only (get-contract-owner)
    CONTRACT_OWNER
)

;; Utility Functions
(define-read-only (get-voter-status (voter-address principal))
    (match (map-get? voters { voter-address: voter-address })
        voter-data {
            registered: (get is-registered voter-data),
            status: (get verification-status voter-data),
            voter-id: (get voter-id voter-data),
            registration-block: (get registration-block voter-data)
        }
        {
            registered: false,
            status: "not-registered",
            voter-id: u0,
            registration-block: u0
        }
    )
)


