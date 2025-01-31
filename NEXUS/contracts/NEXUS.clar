;; Decentralized Crowdfunding Platform Contract
;; Enables users to create and contribute to fundraising campaigns
;; Features campaign management, contribution tracking, and milestone-based releases

;; Constants
(define-constant contract-owner tx-sender)
(define-constant min-campaign-duration u1440) ;; Minimum 1 day (in blocks)
(define-constant max-campaign-duration u432000) ;; Maximum 30 days (in blocks)
(define-constant err-owner-only (err u100))
(define-constant err-invalid-params (err u101))
(define-constant err-campaign-not-found (err u102))
(define-constant err-deadline-passed (err u103))
(define-constant err-goal-not-reached (err u104))
(define-constant err-already-claimed (err u105))
(define-constant err-not-creator (err u106))
(define-constant err-campaign-active (err u107))
(define-constant err-emergency-shutdown (err u108))
(define-constant err-no-contribution (err u109))
(define-constant err-goal-met (err u110))
(define-constant err-already-refunded (err u111))
(define-constant err-invalid-milestone (err u112))

;; Data Variables
(define-data-var campaign-count uint u0)
(define-data-var platform-fee uint u20) ;; 2% fee represented as 20/1000
(define-data-var total-funds-raised uint u0)
(define-data-var emergency-shutdown bool false)
(define-data-var min-contribution uint u1000000) ;; Minimum 1 STX

;; Campaign Status Types
(define-data-var status-funded uint u1)
(define-data-var status-failed uint u2)
(define-data-var status-active uint u3)
(define-data-var status-cancelled uint u4)

;; Maps
(define-map campaigns uint
    {
        creator: principal,
        title: (string-utf8 64),
        goal: uint,
        deadline: uint,
        funds-raised: uint,
        claimed: bool,
        status: uint,
        can-cancel: bool
    })

(define-map contributions 
    { campaign-id: uint, contributor: principal }
    { amount: uint, refunded: bool })

(define-map campaign-milestones uint
    {
        milestone-count: uint,
        milestones-completed: uint,
        milestone-titles: (list 10 (string-utf8 64))
    })

;; Private Functions
(define-private (validate-campaign-params (title (string-utf8 64)) (goal uint) (duration uint))
    (and 
        (>= (len title) u1)
        (> goal u0)
        (>= duration min-campaign-duration)
        (<= duration max-campaign-duration)))

;; Read-only functions
(define-read-only (get-campaign (campaign-id uint))
    (map-get? campaigns campaign-id))

(define-read-only (get-contribution (campaign-id uint) (contributor principal))
    (map-get? contributions { campaign-id: campaign-id, contributor: contributor }))


(define-read-only (get-campaign-milestones (campaign-id uint))
    (map-get? campaign-milestones campaign-id))

;; Create new campaign
(define-public (create-campaign 
    (title (string-utf8 64))
    (goal uint)
    (duration uint))
    (begin
        (asserts! (not (var-get emergency-shutdown)) err-emergency-shutdown)
        (asserts! (validate-campaign-params title goal duration) err-invalid-params)
        
        (let ((campaign-id (var-get campaign-count)))
            ;; Create campaign
            (map-set campaigns campaign-id
                {
                    creator: tx-sender,
                    title: title,
                    goal: goal,
                    deadline: (+ block-height duration),
                    funds-raised: u0,
                    claimed: false,
                    status: (var-get status-active),
                    can-cancel: true
                })
            
            ;; Initialize milestones
            (map-set campaign-milestones campaign-id
                {
                    milestone-count: u0,
                    milestones-completed: u0,
                    milestone-titles: (list)
                })
            
            ;; Increment campaign count
            (var-set campaign-count (+ campaign-id u1))
            (ok campaign-id))))

;; Contribute to campaign
(define-public (contribute (campaign-id uint) (amount uint))
    (let ((campaign (unwrap! (map-get? campaigns campaign-id) err-campaign-not-found)))
        (begin
            (asserts! (not (var-get emergency-shutdown)) err-emergency-shutdown)
            (asserts! (< block-height (get deadline campaign)) err-deadline-passed)
            (asserts! (is-eq (get status campaign) (var-get status-active)) err-campaign-active)
            (asserts! (>= amount (var-get min-contribution)) err-invalid-params)
            
            ;; Transfer STX from contributor to contract
            (try! (stx-transfer? amount tx-sender (as-contract tx-sender)))
            
            ;; Update campaign funds
            (map-set campaigns campaign-id
                (merge campaign 
                    { funds-raised: (+ (get funds-raised campaign) amount) }))
            
            ;; Record contribution
            (map-set contributions 
                { campaign-id: campaign-id, contributor: tx-sender }
                { amount: (+ (default-to u0 
                    (get amount (map-get? contributions 
                        { campaign-id: campaign-id, contributor: tx-sender }))) amount),
                  refunded: false })
            
            ;; Update total funds
            (var-set total-funds-raised (+ (var-get total-funds-raised) amount))
            (ok true))))

;; Claim campaign funds (for creator)
(define-public (claim-funds (campaign-id uint))
    (let ((campaign (unwrap! (map-get? campaigns campaign-id) err-campaign-not-found)))
        (begin
            (asserts! (is-eq tx-sender (get creator campaign)) err-not-creator)
            (asserts! (>= block-height (get deadline campaign)) err-campaign-active)
            (asserts! (>= (get funds-raised campaign) (get goal campaign)) err-goal-not-reached)
            (asserts! (not (get claimed campaign)) err-already-claimed)
            
            ;; Calculate platform fee
            (let ((fee (/ (* (get funds-raised campaign) (var-get platform-fee)) u1000))
                  (final-amount (- (get funds-raised campaign) fee)))
                
                ;; Transfer funds to creator
                (try! (as-contract (stx-transfer? final-amount tx-sender (get creator campaign))))
                ;; Transfer fee to contract owner
                (try! (as-contract (stx-transfer? fee tx-sender contract-owner)))
                
                ;; Update campaign status
                (map-set campaigns campaign-id
                    (merge campaign 
                        { 
                            claimed: true,
                            status: (var-get status-funded)
                        }))
                
                (ok final-amount)))))

;; Request refund (for failed campaigns)
(define-public (request-refund (campaign-id uint))
    (let ((campaign (unwrap! (map-get? campaigns campaign-id) err-campaign-not-found))
          (contribution (unwrap! (map-get? contributions 
            { campaign-id: campaign-id, contributor: tx-sender }) err-no-contribution)))
        (begin
            (asserts! (>= block-height (get deadline campaign)) err-campaign-active)
            (asserts! (or 
                (< (get funds-raised campaign) (get goal campaign))
                (is-eq (get status campaign) (var-get status-cancelled))) err-goal-met)
            (asserts! (not (get refunded contribution)) err-already-refunded)
            
            ;; Transfer refund
            (try! (as-contract (stx-transfer? (get amount contribution) tx-sender tx-sender)))
            
            ;; Process refund
            (map-set contributions
                { campaign-id: campaign-id, contributor: tx-sender }
                (merge contribution { refunded: true }))
            
            (ok (get amount contribution)))))

;; Add campaign milestone
(define-public (add-milestone 
    (campaign-id uint) 
    (milestone-title (string-utf8 64)))
    (let ((campaign (unwrap! (map-get? campaigns campaign-id) err-campaign-not-found))
          (milestones (unwrap! (map-get? campaign-milestones campaign-id) err-campaign-not-found)))
        (begin
            (asserts! (is-eq tx-sender (get creator campaign)) err-not-creator)
            (asserts! (is-eq (get status campaign) (var-get status-active)) err-campaign-active)
            (asserts! (< (get milestone-count milestones) u10) err-invalid-milestone)
            
            (map-set campaign-milestones campaign-id
                {
                    milestone-count: (+ (get milestone-count milestones) u1),
                    milestones-completed: (get milestones-completed milestones),
                    milestone-titles: (unwrap! (as-max-len? 
                        (append (get milestone-titles milestones) milestone-title) u10)
                        err-invalid-milestone)
                })
            (ok true))))

;; Complete milestone
(define-public (complete-milestone 
    (campaign-id uint)
    (milestone-number uint))
    (let ((campaign (unwrap! (map-get? campaigns campaign-id) err-campaign-not-found))
          (milestones (unwrap! (map-get? campaign-milestones campaign-id) err-campaign-not-found)))
        (begin
            (asserts! (is-eq tx-sender (get creator campaign)) err-not-creator)
            (asserts! (<= milestone-number (get milestone-count milestones)) err-invalid-milestone)
            
            (map-set campaign-milestones campaign-id
                (merge milestones 
                    { milestones-completed: (+ (get milestones-completed milestones) u1) }))
            (ok true))))

;; Update campaign status
(define-public (update-campaign-status (campaign-id uint))
    (let ((campaign (unwrap! (map-get? campaigns campaign-id) err-campaign-not-found)))
        (begin
            (asserts! (>= block-height (get deadline campaign)) err-campaign-active)
            
            ;; Update status based on goal achievement
            (map-set campaigns campaign-id
                (merge campaign 
                    { status: (if (>= (get funds-raised campaign) (get goal campaign))
                                 (var-get status-funded)
                                 (var-get status-failed)) }))
            (ok true))))

;; Cancel campaign (creator only)
(define-public (cancel-campaign (campaign-id uint))
    (let ((campaign (unwrap! (map-get? campaigns campaign-id) err-campaign-not-found)))
        (begin
            (asserts! (is-eq tx-sender (get creator campaign)) err-not-creator)
            (asserts! (get can-cancel campaign) err-invalid-params)
            (asserts! (is-eq (get status campaign) (var-get status-active)) err-campaign-active)
            
            (map-set campaigns campaign-id
                (merge campaign 
                    { 
                        status: (var-get status-cancelled),
                        can-cancel: false
                    }))
            (ok true))))

;; Admin functions
(define-public (update-platform-fee (new-fee uint))
    (begin
        (asserts! (is-eq tx-sender contract-owner) err-owner-only)
        (asserts! (<= new-fee u100) err-invalid-params)
        (var-set platform-fee new-fee)
        (ok true)))

(define-public (update-min-contribution (new-min uint))
    (begin
        (asserts! (is-eq tx-sender contract-owner) err-owner-only)
        (var-set min-contribution new-min)
        (ok true)))

(define-public (toggle-emergency-shutdown)
    (begin
        (asserts! (is-eq tx-sender contract-owner) err-owner-only)
        (var-set emergency-shutdown (not (var-get emergency-shutdown)))
        (ok true)))
