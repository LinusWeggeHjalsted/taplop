using UnityEngine;
using UnityEngine.UI;
using UnityEngine.EventSystems;
using System.Collections;

public class SkillButtonScript : MonoBehaviour, IPointerEnterHandler, IPointerExitHandler
{
    public bool finishedBuilding = false;
    public int skillNumber;
    public RectTransform buttonRectTransform;
    public Button button;
    public Image image;
    public GameObject skillsPanel;
    public SkillsPanelScript skillsPanelScript;
    public GameObject turnLogic;
    public TurnLogicScript turnLogicScript;
    public GameObject player;
    public EntityScript playerScript;
    public GameObject skill;
    public Skill skillScript;
    public Sprite noSkillSprite;
    public GameObject tooltipPrefab;
    public GameObject tooltip;

    public GameObject cooldownPrefab;
    public GameObject cooldownOverlay;

    public void OnPointerEnter(PointerEventData eventData)
    {
        if (finishedBuilding && skill != null)
        {
            string skillName = skillScript.GetSkillName();
            string skillDescription = skillScript.GetDescription() + "\n";
            string skillType = skillScript.GetSkillType() + "\n";
            string skillRange = "";
            if (skillScript.GetRange() > 0)
            {
                skillRange = "Range " + skillScript.GetRange().ToString() + "\n";
            }
            string skillCooldown = "";
            if (skillScript.GetCooldown() > 0)
            {
                skillCooldown = "Cooldown " + skillScript.GetCooldown().ToString() + "\n";
            }
            string tooltipText = skillDescription + skillType + skillRange + skillCooldown;

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
                StartCoroutine(tooltipScript.SetText(skillName, tooltipText));
            }
            if (tooltip != null)
            {
                TooltipScript tooltipScript = tooltip.GetComponent<TooltipScript>();
                StartCoroutine(tooltipScript.SetText(skillName, tooltipText));
                tooltip.SetActive(true);
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

    public void DisplayCooldown()
    {
        if (skillScript.CurrentCooldown() > 0)
        {
            if (cooldownOverlay == null)
            {
                cooldownOverlay =  Instantiate(cooldownPrefab, this.transform);
            }
        }
        else
        {
            if (cooldownOverlay != null)
            {
                Destroy(cooldownOverlay);
            }
        }
    }
    
    public void OnActivate()
    {
        switch (turnLogicScript.currentGameState)
        {
            case TurnLogicScript.GameState.PlayerTurnAttack:
                if (skillScript.CurrentCooldown() > 0)
                {
                    Debug.Log("Skill is on cooldown");
                    break;
                }
                Debug.Log("Skill " + (skillNumber + 1).ToString() + " was pressed");
                skillScript.PrepareSkill(player.transform.position, player);
                turnLogicScript.skillUsed = skill;
                break;
        }
    }

    public void UpdateButton()
    {
        skill = playerScript.equippedSkills[skillNumber];
        if (skill == null)
        {
            image.sprite = noSkillSprite;
        }
        else
        {
            skillScript = skill.GetComponent<Skill>();
            image.sprite = skillScript.GetSprite();
        }
    }

    IEnumerator WaitForPlayerLoadout()
    {
        while (!playerScript.finishedBuilding)
        {
            yield return null;
        }
        while (!skillsPanelScript.finishedAssigning)
        {
            yield return null;
        }
        UpdateButton();
        finishedBuilding = true;
    }

    void Start()
    {
        turnLogic = GameObject.Find("Turn Logic");
        turnLogicScript = turnLogic.GetComponent<TurnLogicScript>();
        player = GameObject.Find("Player");
        playerScript = player.GetComponent<EntityScript>();
        buttonRectTransform = this.GetComponent<RectTransform>();
        button = this.GetComponent<Button>();
        button.onClick.AddListener(OnActivate);
        image = this.GetComponent<Image>();
        skillsPanel = this.transform.parent.gameObject;
        skillsPanelScript = skillsPanel.GetComponent<SkillsPanelScript>();
        noSkillSprite = Resources.Load<Sprite>("Skill Sprites/NoSkill");
        tooltipPrefab = Resources.Load<GameObject>("Prefabs/Tooltip");
        cooldownPrefab = Resources.Load<GameObject>("Prefabs/Cooldown Overlay Panel");

        StartCoroutine(WaitForPlayerLoadout());
    }

    void Update()
    {
        if (finishedBuilding && skill != null)
        {
            DisplayCooldown();
        }
    }
}
