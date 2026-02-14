using UnityEngine;
using UnityEngine.UI;
using UnityEngine.EventSystems;
using System.Collections;

public class UnlockedSkillScript : MonoBehaviour, IPointerEnterHandler, IPointerExitHandler, IBeginDragHandler, IDragHandler, IEndDragHandler
{
    public bool finishedBuilding = false;
    public RectTransform rectTransform;
    public Image image;
    public Transform canvas;
    public GameObject player;
    public PlayerCharacterScript playerScript;
    public GameObject skill;
    public Skill skillScript;
    public GameObject tooltipPrefab;
    public GameObject tooltip;
    public GameObject unlockedSkillPrefab;
    public GameObject placeholder;
    public Transform currentParent;
    public int currentSiblingIndex;
    public string skillName; // the name of the unlocked skill this represents

    public void OnPointerEnter(PointerEventData eventData)
    {
        if (finishedBuilding && skill != null)
        {
            string skillDescription = skillScript.GetDescription() + "\n";
            string skillType = skillScript.GetSkillType() + "\n";
            string skillRange = "";
            if (skillScript.GetRange() > 0)
            {
                float effectiveRange = skillScript.GetRange();
                skillRange = "Range " + effectiveRange.ToString() + "\n";
            }
            string skillRadius = "";
            if (skillScript.GetRadius() > 0)
            {
                float effectiveRadius = skillScript.GetRadius();
                skillRadius = "Radius " + effectiveRadius.ToString() + "\n";
            }
            string skillDistance = "";
            if (skillScript.GetDistance() > 0)
            {
                float effectiveDistance = skillScript.GetDistance();
                skillDistance = "Distance " + effectiveDistance.ToString() + "\n";
            }
            string skillDuration = "";
            if (skillScript.GetSkillDuration() > 0)
            {
                int effectiveDuration = skillScript.GetSkillDuration();
                skillDuration = "Skill Duration " + effectiveDuration.ToString() + "\n";
            }
            string skillStunDuration = "";
            if (skillScript.GetStunDuration() > 0)
            {
                int effectiveStunDuration = skillScript.GetStunDuration();
                skillStunDuration = "Stun Duration " + effectiveStunDuration.ToString() + "\n";
            }
            string skillCooldown = "";
            if (skillScript.GetCooldown() > 0)
            {
                skillCooldown = "Cooldown " + skillScript.GetCooldown().ToString() + "\n";
            }
            string tooltipText = skillDescription + skillType + skillRange + skillRadius + skillDistance + skillDuration + skillStunDuration + skillCooldown;
            Vector3[] corners = new Vector3[4];
            rectTransform.GetWorldCorners(corners);
            Vector3 topRightPosition = corners[2];

            // Refresh canvas reference if null
            if (canvas == null)
            {
                canvas = GameReferences.GetCanvasTransform();
            }
            if (canvas == null) return;

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
                tooltipRectTransform.pivot = new Vector2(0f, 1f);
                tooltipRectTransform.position = topRightPosition;
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

    public void OnBeginDrag(PointerEventData eventData)
    {
        // Refresh canvas reference if null
        if (canvas == null)
        {
            canvas = GameReferences.GetCanvasTransform();
        }
        if (canvas == null) return;

        currentSiblingIndex = this.transform.GetSiblingIndex();
        this.transform.parent = canvas;
        this.transform.SetAsLastSibling();
        Image skillImage = GetComponent<Image>();
        skillImage.raycastTarget = false;
        // create placeholder in the menu
        placeholder = Instantiate(unlockedSkillPrefab, currentParent);
        placeholder.transform.SetSiblingIndex(currentSiblingIndex);
    }

    public void OnDrag(PointerEventData eventData)
    {
        this.transform.position = eventData.position;
    }

    public void OnEndDrag(PointerEventData eventData)
    {
        Destroy(placeholder);
        this.transform.parent = currentParent;
        this.transform.SetSiblingIndex(currentSiblingIndex);
        this.transform.localPosition = new Vector3(0, 0, 0);
        Image skillImage = GetComponent<Image>();
        skillImage.raycastTarget = true;
    }

    public void UpdateButton()
    {
        if (skill == null)
        {
            Debug.LogError("UnlockedSkillScript has no skill assigned");
            return;
        }
        skillScript = skill.GetComponent<Skill>();
        image.sprite = skillScript.GetSprite();
        skillName = skillScript.GetSkillName();
    }

    IEnumerator WaitForPlayerLoadout()
    {
        while (!playerScript.finishedBuilding)
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
        // only call UpdateButton if skill wasn't already set by SkillsMenuScript
        if (skill != null && !finishedBuilding) // to-do - think about this
        {
            UpdateButton();
            finishedBuilding = true;
        }
    }

    void Awake()
    {
        currentParent = this.transform.parent;
        rectTransform = this.GetComponent<RectTransform>();
        image = this.GetComponent<Image>();
        tooltipPrefab = Resources.Load<GameObject>("Prefabs/UI/Tooltip");
        unlockedSkillPrefab = Resources.Load<GameObject>("Prefabs/UI/Unlocked Skill");
    }

    void Start()
    {
        // Use GameReferences helper for clean lookups
        player = GameReferences.GetPlayer();
        if (player != null) playerScript = player.GetComponent<PlayerCharacterScript>();
        canvas = GameReferences.GetCanvasTransform();

        StartCoroutine(WaitForPlayerLoadout());
    }
}
