using UnityEngine;
using UnityEngine.UI;
using UnityEngine.EventSystems;
using UnityEngine.InputSystem;

public class SkipButtonScript : MonoBehaviour, IPointerEnterHandler, IPointerExitHandler
{
    public RectTransform buttonRectTransform;
    public Button button;
    public Transform canvas;
    public GameObject turnLogic;
    public TurnLogicScript turnLogicScript;
    public GameObject traversableTiles;
    public TraversableTilesScript traversableTilesScript;
    public GameObject tooltipPrefab;
    public GameObject tooltip;

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
            StartCoroutine(tooltipScript.SetText("Skip Step [space]", ""));
        }
    }

    public void OnPointerExit(PointerEventData eventData)
    {
        if (tooltip != null)
        {
            tooltip.SetActive(false);
        }
    }

    public void OnActivate()
    {
        SoundControllerScript.Instance.PlayButtonClickSound();
        CameraControllerScript.Instance.MoveToPlayer();
        switch (turnLogicScript.currentGameState)
        {
            case TurnLogicScript.GameState.PlayerTurnMove:
                traversableTilesScript.ClearHighlights();
                turnLogicScript.skillUsed = null;
                Keyboard keyboard = Keyboard.current;
                if (keyboard.leftCtrlKey.isPressed || keyboard.rightCtrlKey.isPressed)
                {
                    turnLogicScript.overrideSkipAttackStep = true;
                }
                turnLogicScript.currentGameState = TurnLogicScript.GameState.PlayerTurnAttack;
                turnLogicScript.hasMoved = true;
                break;
            case TurnLogicScript.GameState.PlayerTurnAttack:
                traversableTilesScript.ClearHighlights();
                turnLogicScript.currentGameState = TurnLogicScript.GameState.EnemiesTurn;
                turnLogicScript.hasAttacked = true;
                break;
        }
    }

    void Start()
    {
        turnLogic = GameObject.Find("Turn Logic");
        turnLogicScript = turnLogic.GetComponent<TurnLogicScript>();
        traversableTiles = GameObject.Find("Traversable Tiles");
        traversableTilesScript = traversableTiles.GetComponent<TraversableTilesScript>();
        buttonRectTransform = this.GetComponent<RectTransform>();
        button = this.GetComponent<Button>();
        button.onClick.AddListener(OnActivate);
        canvas = GameObject.Find("Canvas").transform;
        tooltipPrefab = Resources.Load<GameObject>("Prefabs/UI/Tooltip");
    }
}
