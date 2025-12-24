using UnityEngine;
using UnityEngine.InputSystem;
using UnityEngine.EventSystems;

public class TileScript : MonoBehaviour
{
    public GameObject player;
    public PlayerCharacterScript playerScript;
    public GameObject turnLogic;
    public TurnLogicScript turnLogicScript;
    public GameObject highlight;
    public Animator highlightAnimator;
    public bool isOccupied = false;
    private bool isHighlighted = false;
    public bool IsHighlighted 
    {
        get
        {
            return this.isHighlighted;
        }
        set
        {
            this.isHighlighted = value;
            highlightAnimator.SetBool("isHighlighted", isHighlighted);
        }
    }
    private bool isEnd = false;
    public bool IsEnd
    {
        get
        {
            return isEnd;
        }
        set
        {
            if (value == true)
            {
                GameObject endOverlay = new GameObject("End Overlay");
                endOverlay.transform.parent = this.transform;
                endOverlay.transform.localPosition = new Vector3(0, 0, 0);
                SpriteRenderer endRenderer = endOverlay.AddComponent<SpriteRenderer>();
                endRenderer.sortingOrder = 1;
                Sprite endSprite = Resources.Load<Sprite>("Flag");
                endRenderer.sprite = endSprite;
            }
            isEnd = value;
        }
    }

    void Start()
    {
        player = GameObject.Find("Player");
        playerScript = player.GetComponent<PlayerCharacterScript>();
        turnLogic = GameObject.Find("Turn Logic");
        if (turnLogic != null)
        {
            turnLogicScript = turnLogic.GetComponent<TurnLogicScript>();
        }
        highlight = this.transform.Find("Highlight").gameObject;
        highlightAnimator = highlight.GetComponent<Animator>();
    }

    public void OnTileClicked()
    {
        if (!isHighlighted)
        {
            return;
        }
        switch (turnLogicScript.currentGameState)
        {
            case TurnLogicScript.GameState.PlayerTurnMove:
                playerScript.MoveTo(this.transform.position);
                turnLogicScript.hasMoved = true;
                break;
            case TurnLogicScript.GameState.PlayerTurnAttack:
                GameObject skillUsed = turnLogicScript.skillUsed;
                if (skillUsed == null)
                {
                    return;
                }
                Skill skillScript = skillUsed.GetComponent<Skill>();
                skillScript.UseSkill(this.transform.position, player);
                break;
        }
    }
}
