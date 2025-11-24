using UnityEngine;
using UnityEngine.UI;
using UnityEngine.EventSystems;

public class SkipButtonScript : MonoBehaviour, IPointerEnterHandler, IPointerExitHandler
{
    public Button button;
    public RectTransform buttonRectTransform;
    public GameObject turnLogic;
    public TurnLogicScript turnLogicScript;
    public GameObject tooltipPrefab;
    public GameObject tooltip;

    public void OnPointerEnter(PointerEventData eventData)
    {
        if (tooltip == null)
        {
            Vector3[] buttonCorners = new Vector3[4];
            buttonRectTransform.GetWorldCorners(buttonCorners);
            Vector3 buttonTopRightPosition = buttonCorners[2];

            tooltip = Instantiate(tooltipPrefab, this.gameObject.transform);
            RectTransform tooltipRectTransform = tooltip.GetComponent<RectTransform>();
            tooltipRectTransform.pivot = new Vector2(1f, 0);
            tooltipRectTransform.position = buttonTopRightPosition;
            TooltipScript tooltipScript = tooltip.GetComponent<TooltipScript>();
            StartCoroutine(tooltipScript.SetText("Skip step", ""));
        }
        if (tooltip != null)
        {
            tooltip.SetActive(true);
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
        switch (turnLogicScript.currentGameState)
        {
            case TurnLogicScript.GameState.PlayerTurnMove:
                turnLogicScript.currentGameState = TurnLogicScript.GameState.PlayerTurnAttack;
                turnLogicScript.hasMoved = true;
                break;
            case TurnLogicScript.GameState.PlayerTurnAttack:
                turnLogicScript.currentGameState = TurnLogicScript.GameState.EnemiesTurn;
                turnLogicScript.hasAttacked = true;
                break;
        }
    }

    void Start()
    {
        turnLogic = GameObject.Find("Turn Logic");
        turnLogicScript = turnLogic.GetComponent<TurnLogicScript>();
        buttonRectTransform = this.GetComponent<RectTransform>();
        button = this.GetComponent<Button>();
        button.onClick.AddListener(OnActivate);
        tooltipPrefab = Resources.Load<GameObject>("Prefabs/Tooltip");
    }
}
