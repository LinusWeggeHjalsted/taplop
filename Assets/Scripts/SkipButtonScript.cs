using UnityEngine;
using UnityEngine.UI;
using UnityEngine.EventSystems;

public class SkipButtonScript : MonoBehaviour, IPointerEnterHandler, IPointerExitHandler
{
    public Button button;
    public GameObject turnLogic;
    public TurnLogicScript turnLogicScript;
    public GameObject tooltipPrefab;
    public GameObject tooltip;

    public void OnPointerEnter(PointerEventData eventData)
    {
        if (tooltip == null)
        {
            tooltip = Instantiate(tooltipPrefab, this.gameObject.transform);
            TooltipScript tooltipScript = tooltip.GetComponent<TooltipScript>();
            tooltipScript.SetText("Skip", "");
        }
    }

    public void OnPointerExit(PointerEventData eventData)
    {
        if (tooltip != null)
        {
            Destroy(tooltip);
        }
    }

    void Start()
    {
        turnLogic = GameObject.Find("Turn Logic");
        turnLogicScript = turnLogic.GetComponent<TurnLogicScript>();
        button = this.GetComponent<Button>();
        button.onClick.AddListener(OnActivate);
        tooltipPrefab = Resources.Load<GameObject>("Prefabs/Tooltip");
    }

    public void OnActivate()
    {
        switch (turnLogicScript.currentGameState)
        {
            case TurnLogicScript.GameState.PlayerTurnMove:
                turnLogicScript.currentGameState = TurnLogicScript.GameState.PlayerTurnAttack;
                turnLogicScript.turnStarted = false;
                break;
            case TurnLogicScript.GameState.PlayerTurnAttack:
                turnLogicScript.currentGameState = TurnLogicScript.GameState.EnemiesTurn;
                turnLogicScript.turnStarted = false;
                break;
        }
    }
}
