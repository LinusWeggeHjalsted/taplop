using UnityEngine;
using UnityEngine.UI;
using UnityEngine.EventSystems;
using TMPro;
using System;
using System.Collections;

public class SkillButtonScript : MonoBehaviour, IPointerEnterHandler, IPointerExitHandler, IBeginDragHandler, IDragHandler, IEndDragHandler, IDropHandler
{
    public bool finishedBuilding = false;
    public int skillNumber;
    public RectTransform buttonRectTransform;
    public Button button;
    public Image image;
    public Transform canvas;
    public GameObject skillsPanel;
    public SkillBarScript skillBarScript;
    public GameObject turnLogic;
    public TurnLogicScript turnLogicScript;
    public GameObject player;
    public PlayerCharacterScript playerScript;
    public GameObject skill;
    public Skill skillScript;
    public string skillName
    {
        get
        {
            if (skillScript != null)
            {
                return skillScript.GetSkillName();
            }
            else
            {
                return "No Skill Loaded";
            }
        }
    }
    public Sprite noSkillSprite;
    public GameObject tooltipPrefab;
    public GameObject tooltip;
    public GameObject cooldownPrefab;
    public GameObject cooldownOverlay;
    public GameObject skillButtonPrefab;
    public GameObject placeholderButton;
    public Transform currentParent;

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
                float modifierRange = 0;
                if (turnLogic != null)
                {
                    EntityScript playerEntityScript = player.GetComponent<EntityScript>();
                    modifierRange = playerEntityScript.enchantmentModifiers.range;
                }
                float effectiveRange = skillScript.GetRange() + modifierRange;
                skillRange = "Range " + effectiveRange.ToString() + "\n";
            }
            string skillDuration = "";
            if (skillScript.GetDuration() > 0)
            {
                int modifierDuration = 0;
                if (turnLogic != null)
                {
                    EntityScript playerEntityScript = player.GetComponent<EntityScript>();
                    modifierDuration = playerEntityScript.enchantmentModifiers.duration;
                }
                int effectiveDuration = skillScript.GetDuration() + modifierDuration;
                skillDuration = "Duration " + effectiveDuration.ToString() + "\n";
            }
            string skillCooldown = "";
            if (skillScript.GetCooldown() > 0)
            {
                skillCooldown = "Cooldown " + skillScript.GetCooldown().ToString() + "\n";
            }
            string tooltipText = skillDescription + skillType + skillRange + skillDuration + skillCooldown;
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

        if (playerScript.GetSkillCooldown(skillName) > 0)
        {
            if (cooldownOverlay == null)
            {
                cooldownOverlay = Instantiate(cooldownPrefab, this.transform);
            }
            GameObject cooldownText = cooldownOverlay.transform.Find("Cooldown Text").gameObject;
            TMP_Text textField = cooldownText.GetComponent<TMP_Text>();
            textField.text = playerScript.GetSkillCooldown(skillName).ToString();
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
                if (skillScript == null)
                {
                    break;
                }
                if (playerScript.GetSkillCooldown(skillName) > 0)
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
    
    public void OnBeginDrag(PointerEventData eventData)
    {
        this.transform.parent = canvas;
        this.transform.SetAsLastSibling();
        Image skillImage = GetComponent<Image>();
        skillImage.raycastTarget = false;
        // create placeholder button
        placeholderButton = Instantiate(skillButtonPrefab, skillsPanel.transform);
        placeholderButton.transform.SetSiblingIndex(skillNumber);
    }

    public void OnDrag(PointerEventData eventData)
    {
        this.transform.position = eventData.position;
    }

    public void OnEndDrag(PointerEventData eventData)
    {
        Destroy(placeholderButton);
        this.transform.parent = currentParent;
        this.transform.SetSiblingIndex(skillNumber);
        this.transform.localPosition = new Vector3(0, 0, 0);
        Image skillImage = GetComponent<Image>();
        skillImage.raycastTarget = true;
    }

    public void OnDrop(PointerEventData eventData)
    {
        // cannot drop into weapon skill slots (0-2)
        if (skillNumber < 3)
        {
            Debug.Log("cannot switch weaponskills");
            return;
        }
        if (skillNumber > playerScript.utilitySkillSlots + 2)
        {
            Debug.Log("this skill slot is not unlocked yet");
            return;
        }
        GameObject droppedObject = eventData.pointerDrag;
        // check if dropped object is an UnlockedSkillScript (from skills menu)
        UnlockedSkillScript unlockedSkillScript = droppedObject.GetComponent<UnlockedSkillScript>();
        if (unlockedSkillScript != null)
        {
            HandleUnlockedSkillDrop(droppedObject);
            skillBarScript.UpdateButtons();
            return;
        }
        // otherwise, handle SkillButtonScript (skill bar to skill bar swap)
        SkillButtonScript skillButtonScript = droppedObject.GetComponent<SkillButtonScript>();
        if (skillButtonScript == null)
        {
            Debug.Log("not a skill");
            return;
        }
        GameObject droppedSkill = skillButtonScript.skill;
        if (droppedSkill == null)
        {
            Debug.Log("no skill to swap in");
            return;
        }
        Skill droppedSkillScript = droppedSkill.GetComponent<Skill>();
        Skill skillScript = null;
        if (skill != null)
        {
            skillScript = skill.GetComponent<Skill>();
        }
        int droppedSkillPosition = droppedSkillScript.skillBarPosition;
        int ownPosition = skillNumber + 1;
        droppedSkillScript.skillBarPosition = ownPosition;
        if (skillScript != null)
        {
            skillScript.skillBarPosition = droppedSkillPosition;
        }
        skillBarScript.UpdateButtons(); // hacky way to prevent feeling of lag
        StartCoroutine(DelayedUpdateButtons());
    }

    private void HandleUnlockedSkillDrop(GameObject unlockedSkill)
    {
        UnlockedSkillScript unlockedSkillScript = unlockedSkill.GetComponent<UnlockedSkillScript>();
        string droppedSkillName = unlockedSkillScript.skillName;
        if (string.IsNullOrEmpty(droppedSkillName))
        {
            Debug.LogError("UnlockedSkillScript has no skill name");
            return;
        }
        // check if this skill already exists on the bar
        bool skillExists = false;
        GameObject foundSkill = null;
        Skill foundSkillScript = null;
        for (int i = 3; i < playerScript.equippedSkills.Length; i++)
        {
            GameObject equippedSkill = playerScript.equippedSkills[i];
            if (equippedSkill != null)
            {
                Skill equippedSkillScript = equippedSkill.GetComponent<Skill>();
                if (equippedSkillScript.GetSkillName() == droppedSkillName)
                {
                    skillExists = true;
                    foundSkill = equippedSkill;
                    foundSkillScript = equippedSkillScript;
                    break;
                }
            }
        }
        if (skillExists)
        {
            // swap skills on bar
            int foundPosition = foundSkillScript.skillBarPosition;
            if (skill != null)
            {
                Skill ownSkillScript = skill.GetComponent<Skill>();
                int ownPosition = ownSkillScript.skillBarPosition;
                foundSkillScript.skillBarPosition = ownPosition;
                ownSkillScript.skillBarPosition = foundPosition;
            }
            else
            {
                foundSkillScript.skillBarPosition = skillNumber + 1;
            }
        }
        else
        {
            // update cooldown to max of the two being swapped
            int ownCurrentCooldown = playerScript.GetSkillCooldown(skillName);
            int droppedCurrentCooldown = playerScript.GetSkillCooldown(droppedSkillName);
            int maxCurrentCooldown = Math.Max(ownCurrentCooldown, droppedCurrentCooldown);
            playerScript.SetSkillCooldown(droppedSkillName, maxCurrentCooldown);
            // remove old skill from this slot if present
            if (skill != null)
            {
                Destroy(skill);
            }
            // instantiate new skill under player's Utility Skills
            GameObject skillPrefab = Resources.Load<GameObject>("Prefabs/" + droppedSkillName);
            if (skillPrefab == null)
            {
                Debug.LogError("Could not find skill prefab: Prefabs/" + droppedSkillName);
                return;
            }
            Transform utilitySkills = playerScript.utilitySkills;
            GameObject newSkill = Instantiate(skillPrefab, utilitySkills);
            Skill newSkillScript = newSkill.GetComponent<Skill>();
            newSkillScript.skillBarPosition = skillNumber + 1;
        }
        // Wait a frame for the new skill to initialize before updating the UI
        StartCoroutine(DelayedUpdateButtons());
    }

    IEnumerator DelayedUpdateButtons()
    {
        yield return null;
        skillBarScript.UpdateButtons();
    }

    IEnumerator WaitForPlayerLoadout()
    {
        while (!playerScript.finishedBuilding)
        {
            yield return null;
        }
        while (!skillBarScript.finishedAssigning)
        {
            yield return null;
        }
        if (PlayerDataScript.Instance != null)
        {
            while (!PlayerDataScript.Instance.finishedBuilding)
            {
                yield return null;
            }
        }
        UpdateButton();
        finishedBuilding = true;
    }

    void Start()
    {
        currentParent = this.transform.parent;
        turnLogic = GameObject.Find("Turn Logic");
        if (turnLogic != null)
        {
            turnLogicScript = turnLogic.GetComponent<TurnLogicScript>();
        }
        player = GameObject.Find("Player");
        playerScript = player.GetComponent<PlayerCharacterScript>();
        buttonRectTransform = this.GetComponent<RectTransform>();
        button = this.GetComponent<Button>();
        button.onClick.AddListener(OnActivate);
        image = this.GetComponent<Image>();
        canvas = GameObject.Find("Canvas").transform;
        skillsPanel = this.transform.parent.gameObject;
        skillBarScript = skillsPanel.GetComponent<SkillBarScript>();
        noSkillSprite = Resources.Load<Sprite>("Skills/NoSkill");
        tooltipPrefab = Resources.Load<GameObject>("Prefabs/Tooltip");
        cooldownPrefab = Resources.Load<GameObject>("Prefabs/Cooldown Overlay Panel");
        skillButtonPrefab = Resources.Load<GameObject>("Prefabs/Skill Button");
        StartCoroutine(WaitForPlayerLoadout());
    }
}
