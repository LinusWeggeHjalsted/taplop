using UnityEngine;
using UnityEngine.UI;
using UnityEngine.EventSystems;

public class MoveStepButtonScript : MonoBehaviour, IPointerEnterHandler, IPointerExitHandler, IPointerDownHandler
{

    public RectTransform buttonRectTransform;
    public Button button;
    public GameObject highlight;
    public Image highlightImage;
    public Transform canvas;
    public GameObject turnLogic;
    public TurnLogicScript turnLogicScript;
    public GameObject traversableTiles;
    public TraversableTilesScript traversableTilesScript;
    public GameObject tooltipPrefab;
    public GameObject tooltip;
    private float blinkTimer = 0f;
    private float blinkInterval = 0.25f;
    private bool wasBlinking = false;

    void Awake()
    {
        buttonRectTransform = this.GetComponent<RectTransform>();
        button = this.GetComponent<Button>();
        button.onClick.AddListener(OnActivate);
        tooltipPrefab = Resources.Load<GameObject>("Prefabs/UI/Tooltip");
        highlight = this.transform.Find("Move Step Highlight").gameObject;
        highlightImage = highlight.GetComponent<Image>();
    }

    void Start()
    {
        turnLogic = GameReferences.GetTurnLogic();
        turnLogicScript = turnLogic.GetComponent<TurnLogicScript>();
        traversableTiles = GameReferences.GetTraversableTiles();
        traversableTilesScript = traversableTiles.GetComponent<TraversableTilesScript>();
        canvas = GameReferences.GetCanvasTransform();
    }

    public void OnPointerDown(PointerEventData eventData)
    {
        SoundControllerScript.Instance.PlayButtonClickDownSound();
    }

    void Update()
    {
        // Check if undo is available (same conditions as OnActivate)
        bool canUndo = turnLogicScript.currentGameState == TurnLogicScript.GameState.PlayerTurnAttack
                    && !turnLogicScript.hasUsedAnySkill
                    && !turnLogicScript.didMove;

        if (canUndo)
        {
            // Just entered blink mode - initialize
            if (!wasBlinking)
            {
                wasBlinking = true;
                blinkTimer = blinkInterval;
                highlightImage.enabled = true; // Start with highlight on
            }

            // Undo is available - blink the highlight
            blinkTimer -= Time.deltaTime;
            if (blinkTimer <= 0f)
            {
                // Toggle highlight on/off
                highlightImage.enabled = !highlightImage.enabled;
                blinkTimer += blinkInterval;
            }
        }
        else
        {
            // Exited blink mode
            wasBlinking = false;

            // Undo not available - set highlight based on game state
            if (turnLogicScript.currentGameState == TurnLogicScript.GameState.PlayerTurnMove)
            {
                highlightImage.enabled = true;
            }
            else
            {
                highlightImage.enabled = false;
            }
            blinkTimer = blinkInterval; // Reset timer for next time
        }
    }

    public void OnActivate()
    {
        // Check if we're in the attack phase
        if (turnLogicScript.currentGameState != TurnLogicScript.GameState.PlayerTurnAttack)
        {
            return;
        }

        // Check if the player can undo (no skills used, no movement done)
        if (turnLogicScript.hasUsedAnySkill || turnLogicScript.didMove)
        {
            return;
        }

        // Undo is allowed - return to move step
        SoundControllerScript.Instance.PlayButtonClickUpSound();
        CameraControllerScript.Instance.MoveToPlayer();

        // Clear any highlights
        traversableTilesScript.ClearHighlights();

        // Reset to PlayerTurnMove state (following EnemiesTurn pattern)
        turnLogicScript.turnStarted = true;
        turnLogicScript.hasMoved = false;
        turnLogicScript.currentGameState = TurnLogicScript.GameState.PlayerTurnMove;
        turnLogicScript.playerMoveCoroutine = StartCoroutine(turnLogicScript.PlayerTurnMove());

        // Disable attack step highlight
        turnLogicScript.attackStepHighlightImage.enabled = false;
    }

    public void OnPointerEnter(PointerEventData eventData)
    {
        Vector3[] buttonCorners = new Vector3[4];
        buttonRectTransform.GetWorldCorners(buttonCorners);
        Vector3 buttonTopRightPosition = buttonCorners[2];
        Transform tooltipTransform = canvas.Find("Tooltip");
        if (tooltipTransform != null)
        {
            tooltip = tooltipTransform.gameObject;
        }
        if (tooltip == null)
        {
            tooltip = Instantiate(tooltipPrefab, canvas);
            tooltip.name = "Tooltip";
            tooltip.transform.SetAsLastSibling();
        }
        if (tooltip != null)
        {
            RectTransform tooltipRectTransform = tooltip.GetComponent<RectTransform>();
            tooltipRectTransform.pivot = new Vector2(1f, 0);
            tooltipRectTransform.position = buttonTopRightPosition;
            TooltipScript tooltipScript = tooltip.GetComponent<TooltipScript>();
            if (turnLogicScript.currentGameState == TurnLogicScript.GameState.PlayerTurnAttack && !turnLogicScript.didMove && !turnLogicScript.hasUsedAnySkill)
            {
                StartCoroutine(tooltipScript.SetText("Return to Move Step", ""));
            }
            else
            {
                StartCoroutine(tooltipScript.SetText("Move Step", ""));
            }
        }
    }

    public void OnPointerExit(PointerEventData eventData)
    {
        if (tooltip != null)
        {
            tooltip.SetActive(false);
        }
    }

}
